# Theseus Tariff-Calculator Refactor — Consolidated Review

> **Find-and-document only — no code was changed.** Bugs are described with file:line and a
> *suggested* fix, but nothing here has been applied.
>
> **Method.** A 12-dimension adversarial review of the whole `theseus` branch vs `master`
> (merge-base `7779933`, 106 commits, +21.8k/−7.5k across 115 files). Each subsystem was swept by
> a skeptical finder; every finding was then independently re-verified by an adversarial skeptic
> that defaulted to *refuting*; survivors were deduplicated and ranked. Workflow run
> `wf_6d7ad80d-607`.
>
> **Central premise every agent exploited:** the parity gate proves nothing about correctness here,
> because the golden was re-frozen twice (`70b6b97` → `52dab78`) *after* behavior-changing work — so
> "parity GREEN 47/47" is green even on a wrong number baked into the golden. The findings below are
> what the gate is structurally blind to.
>
> **Stats.** 76 raw findings (finders re-ran on resume) → **57 confirmed**, 13 refuted (killed by
> verifiers), 6 uncertain/pending, across all 12 dimensions. Sections A–F below are the synthesis
> agent's cross-dimension dedup (~21 distinct issues) of an earlier survivor set, plus the ★ CRITICAL.
> Verbatim per-finding evidence + verifier reasoning (including all refuted) is in the companion file
> **`docs/theseus_review_findings_detail.md`**.

**30 surviving findings → 21 distinct issues after dedup.** Grouped by subsystem, ranked by
real-world impact. Severities are the adversarially-corrected ones. (The cross-dimension synthesis
in sections A–F below was generated on an earlier survivor set; the **★ CRITICAL** immediately
below was confirmed separately and is the single highest-impact item — it belongs above A1.)

---

## ★ CRITICAL — the published rate panel drops the entire P2-1 timeline split

### X1. `publish_internal` drops boundary-mint / scheduled-activation intervals and mis-dates the owning real intervals
- **Severity: CRITICAL** · **Confirmed** (high confidence, independent verifier + on-disk evidence) · Introduced by refactor
- **Files:** `src/publish_internal.R:142, 282-321` · `src/rate_schema.R:92-93` (`build_rev_intervals`) · `src/00_build_timeseries.R:365-367` (in-memory-only mint append)
- **Why it matters:** The published per-interval rate panel — `actual/snapshots/valid_from=*/rates.parquet`, **the artifact tariff-model consumes** — silently omits every synthetic boundary mint (`bnd_<date>`) and scheduled activation (`sched_*`), and publishes the *owning* real revision's **pre-boundary** rates across the post-boundary window. `publish_internal()` resolves dates via `load_revision_dates()` (CSV only); the `bnd_*`/`sched_*` rows are appended **in-memory** in `build_gather` and never persisted, so `build_rev_intervals`'s `filter(revision %in% revs_built)` drops them. Net effect: (a) minted snapshots never reach the parquet tree, and (b) the owning revision's `valid_until` runs to the next *real* revision −1, so its parquet covers the post-boundary window at the wrong rate. The daily CSVs are fine (gather threads the augmented dates into `run_daily_series`); **only the publish layer was left reading the CSV.** This sits squarely in the parity-gate blind spot — the gate checks `snapshot_*.rds` and the daily CSVs, never the published parquet tree.
- **Evidence:** Empirically confirmed against the on-disk published demo `data/timeseries_split_demo/`: partitions jump `2026-02-12 → 2026-02-24` with **no `valid_from=2026-02-20` partition**, yet golden `52dab78` contains `snapshot_bnd_2026-02-20.rds` (the IEEPA-invalidation mint; `2026-02-20` is not a real revision). Verifier independently re-verified against theseus + master + the on-disk artifacts.
- **If real on a fresh check, this means the entire P2-1 timeline-split effort never reaches published output — it likely outranks A1.** *(Caveat: the demo artifact may predate the current publish path; re-confirm against a fresh publish run before acting. It did not re-surface in the resume's second publish-finder run, though that run produced a different finding set rather than refuting this one.)*
- **Suggested fix (not applied):** Persist the minted/scheduled `{revision, effective_date}` rows (side file or `metadata.rds`) and union them into `rev_dates` before publishing — or derive the synthetic dates from the `bnd_<date>`/`sched_<date>` ids — and make `build_rev_intervals` `stop()`/warn when `revs_built` contains ids absent from `rev_dates` instead of silently dropping them. Add the published parquet panel to the parity harness.

---

## A. SHIPPING CORRECTNESS BUGS (wrong numbers in published output)

### A1. Russia §232 200% surcharge leaks onto steel + the broader annex_2 / Note-39a exemption breaks — baked into the golden, parity-blind
- **Severity: HIGH** · **Confirmed** · Pre-existing (carried over)
- **Files:** `config/policy_params.yaml:271-274` · `src/06_calculate_rates.R:2171-2177` (heading guard), `:1642-1644` (blanket-on-auto-only filter) · `src/authority_adapter.R:122-127`
- **Tests that catch it:** `tests/test_rate_calculation.R:856-869, 872-894, 908-920` (3 absolute invariants, all RED on `snapshot_2026_rev_5.rds`)
- **Merged from 4 findings:** the s232-parity root-cause finding (Russia steel springs), the annex_2/Note-39a heading-preservation finding, and the test-quality "Russia leak baked into golden" finding (the demonstration that parity≠correct).
- **Why it matters:** The aluminum-only 200% rate lands on 6 Russia chapter-73 steel codes (7320*) at 200% vs the intended 50% annex tier — a 150pp per-row error — because the §232 heading-program guard preserves the pre-annex blanket rate for products that also match auto/MHD parts lists. The same heading-guard interaction surfaces 31,746 annex_2 rows (chs 87/84) carrying auto/MHD heading rates. **Both are byte-identical in the re-frozen golden, so "parity GREEN 47/47" is green on a real revenue-relevant rate error.** This is the single concrete proof of the audit's central thesis.
- **Nuance flagged by verifier:** the auto/MHD annex_2 mass (invariants 1 & 3) is a *different* mechanism than the aluminum surcharge (invariant 2) — the surcharge-scoping fix addresses only the 6-row steel-spring sliver; the 31k-row annex_2 mass is a heading-preservation-vs-Note-39a question. **The test (`908-919`) is also over-strict** — it encodes "semi-products only" when the code's real (intentional) invariant is "semi OR heading-program," so part of the "failure" is a test bug, not a rate bug.
- **Suggested action (not applied):** Two separable tasks. (a) Scope the aluminum surcharge to aluminum-classified products (or set Russia's `section_232_country_exemptions` entry to `applies_to:['aluminum']`); (b) reconcile the annex_2 test with the documented heading-preservation policy. Both require a deliberate golden re-freeze.

---

## B. SILENT NO-OP / DROPPED COUNTERFACTUALS (scenario engine produces no effect)

### B1. `set_stacking` is silently dropped by the specs-less 09 daily re-aggregation
- **Severity: HIGH** · **Confirmed** · Introduced by refactor
- **Files:** `src/scenario_ops.R:343-375` (op_set_stacking) · `src/09_daily_series.R:131,155,173,192,220-247,267,290` (specs-less re-stack) · `src/stacking.R:296,303-304,350`
- **Merged from 4 reports** (scenario-ops, stacking ×2, dead-code-completeness — all the same root cause).
- **Why it matters:** 06 honors the scenario stacking in the snapshot, but the published daily panel (the primary artifact) **re-derives** total_rate/total_additional with `default_stacking_policy()` and no specs threaded in — silently reverting a `set_stacking` counterfactual (e.g. 301→content_split) across overall/by-country/by-category/by-authority. The verb is documented as supported and fails *no-op*, not loud. Baseline is parity-safe (default == baseline policy), so the gate cannot see it.
- **Suggested action (not applied):** Thread the spec-derived policy into `build_daily_aggregates` / `compute_net_authority_contributions` (or trust the snapshot's already-stacked total). Until then, `op_set_stacking` should warn loudly that the daily aggregate won't reflect it. *This is the documented Pass-2 item.*

### B2. `set_exempt` on the autos program is a silent no-op
- **Severity: MEDIUM** *(corrected down from high)* · **Confirmed** · Introduced by refactor
- **File:** `src/scenario_ops.R:494-502` (writes `r$auto_exempt`, which the calc no longer reads); autos rate set at `06_calculate_rates.R:1666-1671` (heading path, hts10-keyed, no country dim)
- **Why it matters:** `set_exempt(section_232, autos, {Japan})` validates, succeeds, and writes a field the calculator ignores — the auto tariff still applies to every country. Verifier downgraded to medium: no parity regression, and `auto_exempt` was *already* rate-dead on master, so nothing working was lost — but it's a new verb that silently accepts and ignores input.
- **Suggested action (not applied):** Make `op_set_exempt(autos)` fail loud ("autos have no country-exemption mechanism in the heading path"), or give the autos heading path a real per-country mask.

### B3. Program-level `set_active` / `set_stacking` on IEEPA authorities are silent no-ops
- **Severity: LOW** *(both corrected down from medium)* · **Confirmed** · Introduced by refactor
- **Files:** `src/scenario_ops.R:329-341` (set_active) · `src/stacking.R:213/219` reads only authority-level `$stacking$class`
- **Merged:** the `set_active(ieepa_fentanyl)` no-op and the program-level `set_stacking` no-op — same shape (a supported verb writes a field no reader consumes).
- **Why it matters:** Calc derives IEEPA invalidation only from `ieepa_reciprocal$active$until` (`06:984`), gating both reciprocal AND fentanyl — so a fentanyl-only or program-targeted flip does nothing. The policy builder reads only authority-level stacking class, so the adapter's per-program `primary_metal`/`primary_full` classes are dead metadata too. The main *joint* IEEPA-sunset use case works correctly via the authority-level form. The promised `ieepa` group alias is also unimplemented.
- **Suggested action (not applied):** Reject the ignored forms with a loud error (engine is authority-grained), or read per-authority and document the limitation.

---

## C. PARITY-GATE BLIND SPOTS (real behavior changes vs master, hidden by the re-frozen golden)

These are not bugs — most are intentional, correct policy — but the gate is structurally blind to them because the change predates the golden re-freeze. The actionable item is **auditability / docs**, not code.

### C1. IEEPA universal-exempt list gained date-windowing vs the stated master baseline
- **Severity: LOW** *(corrected down from medium)* · **Confirmed** · Pre-existing (ported origin/master fix `c5b2eb1`)
- **Files:** `src/authority_adapter.R:314-335` · consumed at `06:1043-1047,1215,1286`
- **Why it matters:** Relative to merge-base `7779933`, theseus now exempts *fewer* products in early/mid revisions (594 dated rows). It **matches live origin/master**, so not a regression — but the docstring's "VERBATIM / bit-exact" claim is true only vs the immediate theseus predecessor, not vs the reviewer's `master` baseline. Baked into `eb145ba` (ancestor of both golden refreezes).
- **Suggested action (not applied):** Correct the misleading docstring/commit wording; add an oracle assertion that an early revision does NOT exempt the 2025-11-13-dated codes.

### C2. `is_country_eo_exempt` gained India Annex-II inheritance + ch98 carve-out
- **Severity: LOW** · **Confirmed** · Introduced by refactor (ported fix, `70b6b97`)
- **File:** `src/06_calculate_rates.R:1216-1220, 1287-1291`
- **Why it matters:** Zeroes the country-EO surcharge (+25% India / ch98) for cells where master kept it — moves `rate_ieepa_recip`. Correct policy (note 2(z)(ii)); flag only. The referenced port SHAs exist as objects but aren't ancestors of master/theseus — golden is not byte-comparable to master output for these cells.
- **Suggested action (not applied):** Note in plan doc that golden `70b6b97`+ is not byte-comparable to `master` for country-EO/ch98 cells.

### C3. Floor-exemption static fallback applied date-blind on revs 18-22
- **Severity: LOW** · **Confirmed** · Pre-existing (loader untouched by refactor)
- **Files:** `src/data_loaders.R:93-107` · called `authority_adapter.R:618`
- **Why it matters:** 5 revisions (2025-08-07 → 09-03) both apply the floor AND hit the static fallback, so the *current* floor-exempt set can exempt products before their category legally took effect. Parity-neutral, not refactor-introduced — a standing data-versioning gap.
- **Suggested action (not applied):** Ship per-revision files or add `effective_date_*` columns to the static file and date-gate it.

---

## D. DEFENSIVENESS / FAIL-LOUD GAPS (cannot fire today; future footguns)

### D1. `apply_rate_semantics` coerces a per-row NA floor base to 0 instead of erroring
- **Severity: LOW** *(corrected down from medium)* · **Confirmed** · Introduced by refactor
- **File:** `src/authority_spec.R:264-275` — NA-base guard only catches the scalar case; a vectorized base with embedded NAs → `pmax`→NA → `out[is.na(out)]<-0`.
- **Why it matters:** A genuinely-missing post-MFN base masked as "no extra duty." Latent — every live floor caller pre-coalesces base to 0, so it cannot fire today; differs from master (which propagated the NA).
- **Suggested action (not applied):** Make the missing-base check vectorized/shape-aware.

### D2. Unknown-§232-program guards throw cryptic "subscript out of bounds"
- **Severity: LOW** · **Confirmed** · Introduced by refactor
- **File:** `src/scenario_ops.R:443-445, 474-476` — `is.null(VEC[[prog]])` on an atomic named vector throws instead of returning NULL, so the helpful error strings are dead.
- **Suggested action (not applied):** Use `if (!prog %in% names(...)) stop(...)`.

### D3. Validator gaps + add_program field-narrowing (cluster of low-severity hardening items)
- **Severity: LOW** · **Confirmed** · Introduced by refactor
- **Merged from 3 findings:**
  - `validate_rate` doesn't reject duplicate `by_country`/`by_product_tier` keys → silent first-wins (`authority_spec.R:316-324`).
  - `op_add_program` accepts `flat=0` but `collect_seeded_programs` drops it → zero-coverage no-op (`new_coverage.R:62-66`).
  - `op_add_program` drops every rate layer except `flat` and ignores `stacking/metal/active` (`scenario_ops.R:528-534`).
- **Why it matters:** All are silent contract-narrowings in new code that can mask an authoring error. None fires in the current pipeline (adapters produce unique keys; baseline carries no flat program).
- **Suggested action (not applied):** Add `any(duplicated(names(x)))` to `chk_named_num`; reject `flat==0` or message on drop; forward or fail-loud on unsupported `add_program` fields.

---

## E. DEAD / VESTIGIAL CODE & DOC MISMATCHES (no numeric impact)

### E1. `set_floor` capability gap — `eu_auto_25pct` floor-patch not portable to the new verb set
- **Severity: MEDIUM** · **Confirmed** · Introduced by refactor
- **File:** `src/scenario_ops.R:40-44, 155-167` — deleted `config/scenarios.yaml` had an as-of-date country×product §232 floor patch; no equivalent verb; `set_floor` errors loud.
- **Why it matters:** Real capability regression vs deleted code; `docs/scenarios.md` silently omits the floor capability. Fails loud (regression-tested), so no crash.
- **Suggested action (not applied):** Implement `op_set_floor` on the existing `rate$floors` layer, or explicitly document `eu_auto_25pct` as dropped + uncovered.

### E2. `resolve_rate`'s product-keyed precedence half is never reached in production
- **Severity: LOW** *(corrected down from medium)* · **Confirmed** · Introduced by refactor
- **File:** `src/authority_spec.R:205-233` — all 4 live callers pass `product=NULL`; live 301 tier read directly at `06:~2319`; 232 deals via `s232_deal_records`.
- **Why it matters:** The most-specific half of the "keystone" resolver is exercised only by `test_resolve_rate.R`, never by the pipeline → zero parity coverage. Logic is correct; doc oversells it as load-bearing.
- **Suggested action (not applied):** Route live reads through `resolve_rate(product=...)`, or document the branches as test-only and treat the unit test as a required gate.

### E3. Daily expanded output omits `rate_301_cs` from default_columns
- **Severity: LOW** · **Confirmed** · *Mislabeled: actually pre-existing (the omitting line is byte-identical to master)*
- **File:** `src/09_daily_series.R:561-564`
- **Why it matters:** When A2 (`section_301_content_split_codes`) is non-empty, the per-row panel has a correct total but cannot decompose the content-split-301 component. Output-completeness only.
- **Suggested action (not applied):** Add `rate_301_cs` to default_columns.

### E4. `tpc_additive` total drops `rate_301_cs` (asymmetric with mutual_exclusion)
- **Severity: LOW** · **Confirmed** · Introduced by refactor
- **File:** `src/stacking.R:285-294` — omits `rate_301_cs`; dormant (`section_301_content_split_codes: []` + no live `tpc_additive` caller). `09:224-225` papers over it by zeroing.
- **Suggested action (not applied):** Add `+ rate_301_cs` to the tpc total and `net_301_cs` to the tpc net branch.

### E5. Misc dead-code / doc nits (cluster)
- **Severity: LOW** · all **Confirmed**, no numeric impact
  - `run_comparisons.R` vestigial stub — unimplemented `--etrs`, `--tpc` depends on deleted `data/tpc/` (introduced/left by refactor).
  - Dead "fall back to autos rate" arm in `resolve_heading_rate` `06:279` (carried over from master).
  - `new_coverage.R:16-18` header claims "Sourced via helpers.R" but helpers.R doesn't source `authority_spec.R` (only `resolve_country_scope` is genuinely unmet).
  - Stale `run_alternative_series` docstring claiming a `tpc_additive` alternative it no longer performs (`09:1526`).
  - Un-ported `policy_params.yaml` comment block (functional keys present) (`~691-694`).
  - gz-asymmetry in the standalone-scraper drift check (`01_scrape_revision_dates.R:367`) — diagnostic-only.

---

## F. TEST-INFRASTRUCTURE GAPS (the safety net is weaker than the docs claim)

### F1. `test_alt_runner_equivalence.R` is RED right now
- **Severity: HIGH** · **Confirmed** · Introduced by refactor
- **File:** `tests/test_alt_runner_equivalence.R:64-86` — stub `build_alternative_timeseries` lacks the `operations` arg that `.run_one_alt` (`parallel.R:427`) now passes (commit `d51e047`). All 3 specs error; assertion fails; **exit 1**.
- **Why it matters:** A live-path serial unit guard (alt_workers=1, the real build path at `09:1588`) is broken — zero failure-isolation coverage, would mask a real regression. Test-only break; production is consistent.
- **Suggested action (not applied):** Add `operations = NULL` (ideally `snapshot_out_dir=NULL, allow_partial=FALSE`) to the stub.

### F2. Absolute-invariant suites silently exit 0 when build data is absent
- **Severity: MEDIUM** · **Confirmed** · Pre-existing (pattern), but it's the documented backstop for the parity blind spot
- **Files:** `tests/test_timeline_invariants.R:34-49` (`quit(status=0)` in skip_all) · `test_rate_calculation.R:33-45` (skips never set fail_count); `.github/workflows/ci.yml` has no snapshot-build step.
- **Why it matters:** The doc names these as the *only* guard against golden-blindness — but in CI / fresh checkout they go green having asserted nothing (snapshots are gitignored). **The documented Russia backstop (A1) skips in CI.** This is what makes A1 dangerous: the one net that catches it doesn't run automatically.
- **Suggested action (not applied):** Make a skipped invariant exit non-zero (or emit a machine-detectable SKIPPED marker), or run them in a build-data-present job and assert pass_count above a floor.

### F3. No committed STREAMING == MONOLITH equivalence test
- **Severity: MEDIUM** · **Confirmed** · Introduced by refactor
- **Files:** `src/09_daily_series.R:1001-1067` (streaming) · `quality_report.R:378` — equivalence rests on one-off Slurm job `13800647` + a golden re-frozen *after* the streaming work landed.
- **Why it matters:** A streaming relocation that moved a number and got baked into the golden is invisible to parity. No live divergence found — purely a missing regression guard for the schema-NA union, per-revision denominators, parts-bind ordering.
- **Suggested action (not applied):** Add a synthetic 3-revision fixture test asserting monolith == parts/streaming path for daily + quality.

### F4. Largest §232 relocations lack an oracle test
- **Severity: LOW** *(corrected down from medium)* · **Uncertain** · Introduced by refactor
- **File:** `tests/test_authority_adapter.R:141-194`
- **Why it matters:** Unlike IEEPA/exempt (faithful oracle tests), the §232 blanket overlay (`.s232_blanket_by_country` merge precedence + config-exemption date gate) and the UK annex replace mode have no master-as-oracle test. **Verifier downgraded to uncertain/low:** the finding overstated it — `run_tests_daily_series.R:1414,1599` *does* cover the annex flat-rate map and the max-mode surcharge end-to-end (non-data-gated). The genuine gap is narrower: the blanket overlay precedence + date boundary, and UK replace.
- **Suggested action (not applied):** Add a small `test_s232_deblob.R` oracle for the blanket overlay + UK replace branch.

### F5. Weighted-ETR aggregation has zero parity coverage under the standard `--unweighted` gate
- **Severity: LOW** *(corrected down from medium)* · **Confirmed** · Introduced by refactor
- **File:** `src/parity.R:94-105, 144-146` — skips `^weighted_etr|^etr_|_imports_b$`; standard gate runs `--unweighted` vs a WEIGHTED golden.
- **Why it matters:** The weighting/denominator math is never value-compared. **Verifier corrected the key premise:** tariff-model consumes only the rate panel (which IS gated), NOT the weighted CSVs — so the blast radius is published headline/chart numbers, not model inputs. Deliberate + documented.
- **Suggested action (not applied):** Run one gate weighted vs the weighted golden, or freeze a separate unweighted golden.

### F6. Test-quality nits (cluster)
- **Severity: LOW** · **Confirmed**
  - Vacuous "rate_301 only for China" assertion — passes even with no China gate (`test_rate_calculation.R:411-430,476-481`); pre-existing.
  - Relocated `$exempt_products` sets + `rate$resolved` blob are invisible to `validate_authority_spec` — no schema guard on relocated payloads (`test_authority_spec.R`, by design); introduced by refactor.
  - `run_daily_series(snapshot_dir=)` STOPs on stale parts cache, never falls back to `build_daily_aggregates_streaming` — contradicts plan doc; `_streaming` is dead on the gather path (`09:1082-1098`); fail-loud, introduced by refactor.

---

## REFACTOR-INTRODUCED vs PRE-EXISTING (at a glance)

**Pre-existing / carried over from master** (the refactor faithfully relocated, didn't cause): A1 (Russia leak + annex_2 test), C1 (date-window, ported), C3 (floor fallback), E3 (default_columns), E5 (autos fallback arm, yaml comment), F2 (silent-skip pattern), F6 (vacuous 301 assertion).

**Introduced by the refactor** (everything in the new spec/scenario/streaming code): B1, B2, B3, C2, D1, D2, D3, E1, E2, E4, E5 (run_comparisons, new_coverage header, docstrings), F1, F3, F4, F5, F6 (validator-invisible payloads, streaming fallback).

---

## THE FIX-FIRST LIST

0. **X1 — Confirm + fix the published-panel mint drop.** *First re-confirm against a fresh publish run* (the evidence is a possibly-stale demo artifact). If it holds, this is the top priority — the P2-1 timeline split never reaches the artifact tariff-model reads. Persist the synthetic rev_dates into the publish path and gate the parquet tree.

1. **F1 — Fix `test_alt_runner_equivalence.R` (add `operations=NULL` to the stub).** It is RED *now*, the cheapest fix on the list, and it currently masks the live serial alt-runner path. One-line repair; do it immediately.

2. **A1 — Russia §232 aluminum-surcharge leak (the 6 steel-spring rows).** A real, revenue-relevant 150pp-per-row rate error in shipping output, baked into the golden where parity can't see it. Scope the surcharge to aluminum products, then re-freeze the golden. (Treat the 31k-row annex_2 mass and its over-strict test as a separate, paired reconciliation.)

3. **B1 — Thread stacking policy into the 09 daily re-aggregation.** A *supported, advertised* counterfactual verb silently produces baseline output in the primary published panel. Highest-impact silent no-op. At minimum land the loud warning now; the full thread is the documented Pass-2 item.

4. **F2 — Make the absolute-invariant suites fail (not exit 0) when build data is missing, and run them in a data-present CI job.** This is the force-multiplier: it is the *only* net that catches A1 and the other golden-blind drifts, and today it silently passes in CI. Fixing it converts the whole "parity≠correct" class of risk from invisible to caught.

5. **E1 — Implement `op_set_floor`** (or explicitly document the `eu_auto_25pct` §232 floor-patch as dropped + uncovered in `docs/scenarios.md`). The only genuine *capability regression* vs the deleted YAML engine; users will hit the loud error expecting portability.

---

## Notes on this review's own completeness

- The **completeness-critic** pass (which flags subsystems no finder covered — e.g. concurrency in
  the array build, RDS serialization/versioning, CSV locale/encoding) had not returned at write time.
  Resume `wf_6d7ad80d-607` or re-harvest to fold it in.
- Sections A–F are the synthesis agent's cross-dimension dedup of an earlier survivor set; the
  **★ CRITICAL X1** was confirmed separately (a harvest-dedup artifact had briefly dropped it). The
  **full superset** — 76 raw findings, 57 confirmed, 13 refuted, 6 pending, across all 12 dimensions,
  with verbatim evidence + verifier reasoning — is in `docs/theseus_review_findings_detail.md`. Where
  the two differ, trust the detail file's per-finding verdicts.
