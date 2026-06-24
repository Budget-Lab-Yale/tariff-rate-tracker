# Assessment of the Codex review (`phase0-parallel-build`)

**Date:** 2026-06-04
**Reviewed branch:** `phase0-parallel-build` (the full AuthoritySpec migration, Phases 0–8)
**Method:** Every one of Codex's 9 findings was checked against the *current* source (not the cited line numbers, which had drifted a few lines each). Six parallel sub-agents traced the live execution path; the five economically-serious findings (1, 2, 4, 5, 6) and the API finding (8) were then re-read line-by-line directly. Conclusions below are first-hand verified, with `file:line` citations you can click.

---

## Bottom line

**Codex's review is legitimate and unusually high quality.** It correctly located real code, calibrated severity well (it flagged the right findings as serious and the right ones as minor), and its one-line closing diagnosis is exactly right:

> *"The code needs calculator-level tests proving that each scenario op changes actual tariff outputs, not only the intermediate spec object."*

Tally after verification:

| | Count | Findings |
|---|---|---|
| **Confirmed real bugs** | 5 | 1, 2, 4, 5, 8 |
| **Confirmed stale test** (blocks the smoke gate) | 1 | 6 |
| **Partially confirmed** (real gap, framing overstated) | 1 | 3 |
| **Known/already-deferred** (+ a sharper restatement) | 1 | 7 |
| **By-design or already being fixed** | 1 | 9 |

There are **no false positives** — even the "overstated" items point at something real.

### Why this matters: the parity gate is blind to exactly these bugs

The entire migration was gated on one thing: **the baseline build stays byte-identical.** That gate is rock-solid for what it covers — but it is *structurally blind* to every scenario bug, because **all the scenario machinery is dormant in the baseline** (no `set_rate`, no `add_program` in a normal build). So a bug that leaves the baseline perfect but corrupts a scenario sails straight through the gate. That is precisely the shape of findings **1, 2, 4, 5** — each is byte-identical in baseline and wrong only under a scenario.

The existing unit tests don't catch them either, because `tests/test_scenario_ops.R` asserts on the **spec object** (`has_232` flipped, program appended) — not on the **calculator output** (did a copper HTS10 actually get the new rate?). The spec mutates correctly; the calculator then ignores or mis-reads it.

**One detail makes this concrete and a little alarming:** the *one* `set_rate` example that was validated on the real grid — "bump steel to 0.99" (Slurm 13756016) — happens to be the *one* 232 program that is on the safe, spec-driven path. Every *other* 232 program (copper, semiconductors, autos, wood, MHD, buses…) is broken for `set_rate` (findings 1 + 2). The green demo created false confidence in a feature that mostly doesn't work.

---

## Prioritized recommendations

### Tier 1 — Scenarios silently produce wrong numbers (fix before trusting any 232 or new-coverage scenario)

1. **`set_rate` on any Section 232 *heading* program is ignored or applies the wrong rate.** (Findings **1 + 2**, they compound.) Affects copper, semiconductors, autos, auto_parts, MHD, MHD parts, buses, softwood, wood furniture, kitchen cabinets. Steel, aluminum, and Section 122 are **safe**.
2. **New coverage (`add_program`) is missing from the statutory export** that feeds `tariff-etrs` / `tariff-model`. (Finding **5**.) The tracker's own total is right, but the clean downstream interface under-counts the new program — directly corrupting the [[consolidation-goal]] pipe.

### Tier 2 — Diagnostics lie even when totals are right

3. **New coverage is missing from the by-authority ETR breakdown.** (Finding **4**.) The headline ETR moves, but the authority decomposition doesn't say which authority caused it — and the named authorities no longer sum to the total.

### Tier 3 — Robustness, gates, API contract

4. **A scenario rebuild can silently publish a *partial* daily panel that looks complete.** (Finding **3**.) Also affects the baseline build. Fix = fail-loud on missing revisions, opt-in best-effort.
5. **A stale unit test fails, so the smoke suite can't go green.** (Finding **6**.) The test encodes the old "301 is China-only" rule that Phase 2e deliberately removed. Fix the test, not the code.
6. **`add_program`'s documented "authority defaults to other" doesn't work.** (Finding **8**.) Cosmetic/API only — fail-loud with a clear message. One-line fix.

### Tier 4 — Known, by-design, or already in progress (no new action, or PM decision)

7. **Mid-interval scenario dates only land on revision boundaries.** (Finding **7**.) The baseline IEEPA Feb-20-vs-24 piece is the *already-documented* modeling decision left to John. The scenario-granularity angle is a real but low-priority follow-up (hooks already exist).
8. **`--workers` is a no-op / `build_gather.R` hardcoded the output dir.** (Finding **9**.) `--workers` being serial is by design (the Slurm array is the real parallelism). The `build_gather.R` hardcode was real at `HEAD` but **is already being fixed in the working tree** (it now honors `TARIFF_TS_DIR`).

### The systemic fix (do this alongside Tier 1)

Add a **calculator-output scenario test harness**: for each ops verb, run `calculate_rates_for_revision` (or a small fixture revision) with the op applied and assert the **output panel** changed correctly — e.g. "after `set_rate(section_232, copper, 0.25)` on a copper-active revision, a known copper HTS10 has `rate_232 == 0.25`." This is the gate the byte-identical baseline check can never be. It would have caught 1, 2, 4, and 5.

---

## Per-finding detail

### Finding 1 — 232 heading `set_rate` blocked by a stale gate cache — **CONFIRMED (high)**

- The adapter precomputes and caches the activation gates from the *original* parser rates: `attr(section_232, 'heading_gates') <- compute_heading_gates(s232_rates)` (`src/authority_adapter.R:109`).
- `set_rate` mutates the resolved rate and `has_232` but **never touches the cached gate**: `r[[field]] <- rate; r$has_232 <- .s232_recompute_has_232(r)` (`src/scenario_ops.R:226-227`); commit only writes `programs[[1]]$rate$resolved` (`:55-58`).
- The calculator prefers the cached gate; the recompute fallback never fires in production (a non-NULL `s232_rates` is always present): `heading_gates <- attr(specs[['section_232']], 'heading_gates', exact = TRUE) %||% compute_heading_gates(s232_rates)` (`src/06_calculate_rates.R:1382-1383`).
- A FALSE gate is a hard skip: `if (!gate_val) { message('Skipping...'); next }` (`src/06_calculate_rates.R:1400-1404`).
- **Build order confirms staleness:** specs are built (gate cached) → `apply_operations` (mutates rate, not gate) → calc reads stale gate. (`src/00_build_timeseries.R:118-138`, mirrored `src/09_daily_series.R:1154-1172`.)

**Impact:** `set_rate(section_232, copper, 0.50)` to *activate* a program that is dormant in that revision (e.g. copper before its Ch99 codes exist → cached `copper = FALSE`) sets the rate and flips `has_232`, but the calculator skips copper entirely → **no copper products get any rate.** (Changing an *already-active* heading isn't blocked by this — it's then defeated by Finding 2 instead.)

**Fix:** in `op_set_rate`'s section_232 branch, recompute the gate from the new payload before committing — `compute_heading_gates()` is already a pure function of the resolved fields:
```r
spec <- .op_set_resolved(spec, r)
attr(spec, 'heading_gates') <- compute_heading_gates(r)
specs[[auth]] <- spec
```
Do the same in `disable`/`set_exempt`. **Proving test:** after `set_rate(copper, 0.50)` on a spec whose baseline gate is FALSE, assert `attr(result[['section_232']], 'heading_gates')[['copper']] == TRUE` (fails today); plus a calc-output test that a copper HTS10 gets a rate.

---

### Finding 2 — 232 heading rates overridden by YAML defaults — **CONFIRMED (high)**

- The heading rate comes from config, not the spec: `rate = cfg$default_rate %||% s232_rates$auto_rate` (`src/06_calculate_rates.R:1411`).
- **Every heading carries a non-null `default_rate`** (`config/policy_params.yaml:104-163`: autos 0.25, copper 0.50, softwood 0.10, wood/cabinets/MHD/auto_parts 0.25, buses 0.10, semiconductors 0.25). Since the left operand of `%||%` is always present, the spec-resolved fallback is **unreachable** for every heading.
- That `cfg` rate flows through `heading_232_rate → heading_rate_adj → blanket_232 → rate_232 = pmax(rate_232, blanket_232)` (`src/06_calculate_rates.R:1620-1630`), so it is the rate actually applied.
- **`set_rate` writes a field the heading path never reads:** the `S232_RATE_FIELD` map (`src/scenario_ops.R:44-46`) writes `copper→copper_rate`, `autos→auto_rate`, etc.; none of those is consulted at `:1411`.
- **Steel/aluminum are safe** — they read the spec-resolved payload: `steel_rate = if_else(steel_exempt, 0, s232_rates$steel_rate)` (`:1547-1549`), and steel/alum chapters take `blanket_232` from the country-level value, not the heading (`:1625-1626`).

**Impact:** `set_rate(section_232, copper, 0.25)` → copper products still dutied at the YAML **0.50**. The scenario rate is silently discarded for every heading program.

> *Autos caveat:* `set_rate(autos)` writes `auto_rate`, which the country table computes (`:1549`) but the join at `:1611-1612` pulls only `steel_rate_232`/`alum_rate_232` — auto product rates come entirely from the heading YAML path. So `set_rate(autos)` looks doubly inert; **confirm whether country-level `auto_rate` is consumed anywhere downstream** when implementing the fix.

**Fix:** read the heading rate from the spec-resolved field first, YAML only as fallback. Needs a heading-name→resolved-field map because the config keys (`autos_passenger`, `mhd_vehicles`, `kitchen_cabinets`…) don't 1:1 match the resolved fields (`auto_rate`, `mhd_rate`, `wood_rate`) — a deliberate mapping step, not a one-liner. **Must be fixed jointly with Finding 1** (otherwise activating a dormant heading is still skipped before the rate is read). **Proving test:** on a copper-active revision, `set_rate(copper, 0.25)` → a copper HTS10 has `rate_232 == 0.25`, not 0.50.

---

### Finding 4 — `rate_other` dropped from the weighted-ETR by-authority output — **CONFIRMED (high), attribution-only**

- `net_other` *is* computed and selected into `snapshot_net` (`src/08_weighted_etr.R:347`, and the policy-aligned branch `:401`).
- …then **dropped** from the returned `rated` table: the final `select()` lists `net_232, net_ieepa, net_fentanyl, net_301, net_s122, net_section_201` — no `net_other` (`:372-374` and `:407-409`).
- The by-authority aggregation therefore has no `etr_other`: `by_authority` emits `etr_total, etr_232, etr_ieepa, etr_fentanyl, etr_301, etr_s122, etr_section_201` (`:489-501`). Same omission in the plot (`:651-653`, `:696-703`).
- **Totals are correct:** `etr_total = sum(total_rate * imports)/total_imports` (`:492`) and `total_rate` includes the other contribution (`src/stacking.R:223`). So the headline moves; the named authorities just won't sum to it.

**Corroboration this is an oversight, not intent:** the sibling consumer of the *same* helper, `src/09_daily_series.R:234,248`, keeps `net_other`/`etr_other` end-to-end. Only `08_weighted_etr.R` drops it.

**Fix:** add `net_other` to the two `select()`s (`:374`, `:409`), add `etr_other` to the `by_authority` summarise (`:498`), and add it to the plot pivot/labels/colors. Mirror `09_daily_series.R`. **Proving test:** a one-program `add_program` scenario where `etr_total − (sum of the six named etr_*) > 0` while no `etr_other` column exists.

---

### Finding 5 — New coverage stale in the statutory ETR export — **CONFIRMED (high), split-brain**

- The statutory snapshot is taken **before** new coverage: `statutory_rate_other = rate_other` (`src/06_calculate_rates.R:2535`).
- `apply_new_coverage_programs()` runs ~240 lines later (`:2774`) and writes **only** `rate_other` (`src/new_coverage.R:99-103` — `mutate` + `add_blanket_pairs`), never `statutory_rate_other`. Nothing re-syncs it afterward (`enforce_rate_schema` passes `statutory_*` through untouched).
- The export reads the stale snapshot: `other = statutory_rate_other` (`src/generate_etrs_config.R:378`).
- **"Statutory" is a deliberate pre-stacking snapshot, but that doesn't excuse this:** for the additive `other` authority, stacking doesn't scale the rate down, so baseline `statutory_rate_other == rate_other`. The *only* thing that breaks the equality is new coverage being added after the snapshot.

**Impact:** for any `add_program` scenario, the tracker's live `rate_other`/totals include the new program, but the `statutory_rates.csv.gz` "other" column handed to `tariff-etrs`/`tariff-model` **omits it** → downstream under-tariffs exactly the new-coverage products. Combined with Finding 4, a new-coverage scenario is invisible in both the decomposition *and* the downstream interface.

**Fix:** snapshot/refresh `statutory_rate_other` **after** `:2774` (pre-stacking is fine; just post-new-coverage), and make sure `add_blanket_pairs`-seeded new pairs get `statutory_rate_other` populated, not left at 0. **Proving test:** in a new-coverage scenario's exported CSV, the `other` column matches the live `rate_other` on the covered pairs.

> **Orthogonal note (not part of this bug):** `generate_etrs_config.R:373` exports `ieepa_reciprocal = rate_ieepa_recip` — the *live* post-stacking rate — while every other authority on `:372-378` uses `statutory_rate_*`. Probably intentional (recip isn't stacked-down), but worth a one-line confirm while you're in this function.

---

### Finding 3 — Scenario rebuild can silently publish a partial panel — **PARTIALLY CONFIRMED (high on mechanism)**

- The cited construct is real: a per-revision `tryCatch({...}, error = function(e) message('SKIP ...'))` inside the rebuild loop, with the **only** guard being all-empty (`if (n_saved == 0L) warning(...)`) — `src/09_daily_series.R:1139-1186`. Intervals are then derived from whatever snapshots landed on disk (`:1189-1192`), and output is written with no revision-count check.
- **No completeness reconciliation exists anywhere** — not in the in-process path, not in the array gather (`scripts/build_gather.R:55-62`), not in `assemble_timeseries` (`src/00_build_timeseries.R`). The expected revision set (`revisions_to_process`) is never diffed against what was built.
- A dropped middle revision doesn't even leave a visible gap: `build_rev_intervals` stretches the previous revision's window to cover it (`:944`) — so a missing revision reads as *policy stability*, exactly Codex's concern.

**Where Codex overstates:** a *malformed scenario* fails **deterministically on every revision** (op validators depend on structure, not data), so it hits the all-empty guard and is marked `failed` — it's all-or-nothing, not partial. A genuinely *partial* panel needs a **data/IO** failure on one revision (corrupt archive JSON, OOM, one bad parse) — which is equally a hazard for the **baseline** build (`src/00_build_timeseries.R:498-503`, which at least logs a warning the scenario path lacks). So the defect is real and worth fixing, but it's a build-robustness gap across *all* per-revision builds, not a scenario-validation gap, and the specific "bad scenario → silent partial" story is the least-likely trigger.

**Fix:** after the loop, `setdiff(revisions_to_process, revs_built)` and `stop()` (fail-loud) unless an explicit `allow_partial = TRUE` is passed; record expected/skipped in metadata. Apply in both `build_alternative_timeseries` and `assemble_timeseries`/gather.

---

### Finding 6 — Documented daily-series smoke test fails — **CONFIRMED (very high); it's a stale test, not a code bug**

- The test feeds a synthetic Germany row (`country 4280`, `rate_301 = 0.25`, `rate_232 = 0`, `rate_ieepa_recip = 0.15`, `rate_s122 = 0.10`) and asserts `total_additional == 0.25` (i.e. 301 excluded) — `tests/run_tests_daily_series.R:683-696`.
- Current stacking makes 301 **additive with no country check**: `rate_301 = list(net = 'net_301', class = 'additive')` (`src/stacking.R:147`). With `rate_232 = 0`, the content-split authorities also apply at full rate, so the real result is `0.15 + 0.25 + 0.10 = 0.50`. **The assertion fails deterministically** (pure in-memory math, no build needed). The companion China test (`:698-710`, expects 0.79) still passes.
- This is the locked Phase 2e design — 301 country scope is enforced *upstream* in the calculator (`country %in% scope_301`, `src/06_calculate_rates.R:2346-2357`), and "301 → Vietnam" was proven (Slurm 13740049). Baseline still has zero off-China `rate_301 > 0` rows, so baseline numbers are unaffected; only the smoke gate is stuck red.

**Fix (do NOT restore China-only in the stacker — that would break the re-scope capability):** rewrite the assertion to the additive contract (Germany → expect **0.50**), rename it ("stacking treats rate_301 as additive; scope is enforced upstream"), and optionally add a calc-level test asserting baseline produces zero off-China `rate_301`. **Proving check:** `Rscript tests/run_tests_daily_series.R` ends with `fail_count == 0`.

---

### Finding 7 — Mid-interval timing not wired into the live splitter — **KNOWN-DEFERRAL + a real scenario follow-up**

- The live splitter feeds **only expiry boundaries**: `exp_bounds <- expiry_boundaries(policy_params)` (`src/09_daily_series.R:321`), which returns only Section-122/Swiss adjustments. The comprehensive `collect_schedule_boundaries()` (`src/timeline.R:57-86`) — which would add IEEPA invalidation and spec `active` windows — **is never called** anywhere; `active$from` is read by no live code.
- **The baseline IEEPA piece is the already-documented decision left to John** (Feb-20 ruling vs Feb-24 CBP termination; default build keeps IEEPA live through Feb-23). Documented at `src/09_daily_series.R:313-320`, `docs/policy_timing.md:55`, and flagged in the migration plan. Not a new bug. *(Minor doc nit: `policy_timing.md:55` vs `:88-120` disagree on whether the current build uses Feb-20 or Feb-24 — worth reconciling.)*
- **The genuine additional gap:** `build_daily_aggregates` has no `specs` parameter, so a scenario `set_active(..., until = "2026-02-20")` only takes effect at *revision* granularity — the mid-interval date is **never consulted** (Codex's "silently snaps to a boundary" is the wrong mechanism; it's "never seen"). Low priority — no current scenario uses mid-interval dates, and the hooks (`timeline.R`) already exist and are validated.

**Fix (follow-up, not urgent):** thread `specs` into `build_daily_aggregates`, swap `expiry_boundaries` for `collect_schedule_boundaries`, and pair it with invalidation zeroing. Resolve the Feb-20/24 modeling question (John).

---

### Finding 8 — `add_program` "authority defaults to other" is unreachable — **CONFIRMED (very high); cosmetic/API**

- The dispatcher requires `authority` for *all* verbs before dispatching: `auth <- op$authority %||% stop(...)` (`src/scenario_ops.R:86`) — it errors before the `switch` at `:92`.
- So `op_add_program`'s `auth <- op$authority %||% 'other'` (`:267`) can never select `'other'` for the omitted case, and the function's own comment promising "default `other`" (`:259-260`) is contradicted by the framework.

**Impact:** low — fail-loud with a clear message (`missing 'authority'`), zero numerical impact. No documented *example* omits `authority` (the worked examples in `docs/authority_spec.md:407` and `docs/scenarios.md` all include it), so the real contradiction is internal (code comment vs dispatcher), not a user-facing doc trap.

**Fix:** exempt `add_program` from the dispatcher's authority-required check (resolve the default before the `switch`), honoring the Phase-8 design that new programs ride the `other` catch-all — or, if you'd rather require it, delete the dead `%||% 'other'` and fix the comment. **Proving test:** an `add_program` op omitting `authority` lands on `other` without error.

---

### Finding 9 — Some parallel work is scaffolding — **(a) by-design; (b) already being fixed**

- **(a) `--workers` no-op / serial local loop:** real but *intentional and documented* — `src/00_build_timeseries.R:30` labels `--workers` "currently no-op"; the main loop is a serial `for` (`:434`); `parallel_lapply_revisions()` is an explicit "Phase 3 stub" with zero callers. The real parallelism is the **Slurm array** (one revision per task), which is complete and the documented primary path. **Not a defect.** *(Cosmetic: the `src/parallel.R:26` header comment claims it "always falls back to serial," but the body does fork when `workers > 1` — stale comment, harmless.)*
- **(b) `build_gather.R` hardcoded `data/timeseries`:** **true at committed `HEAD`** (Codex was right), and a genuine latent footgun — with `TARIFF_TS_DIR` set for the writer only, gather would read a stale default dir and assemble a stale-but-successful-looking panel (no freshness guard). **But the working tree already fixes it** — `scripts/build_gather.R` now reads `TARIFF_TS_DIR` symmetrically with `build_revision.R`. The supported default-dir workflow was never exposed (both sides defaulted to the same dir); only manual partial-override was fragile.

**Action:** just commit the in-flight `build_gather.R` fix; optionally drop/relabel `--workers` and the stale `parallel.R:26` comment. Consider a gather freshness guard (refuse to assemble snapshots older than the run) to close the stale-read class entirely.

---

## Appendix — verification notes

- **Line drift:** Codex's cited lines were all within ~0–10 lines of the truth (e.g. heading-rate `%||%` cited `06:1409`, actual `06:1411`; statutory export cited `:370`, actual `:378`). No citation was wrong enough to matter.
- **Not the resolved-stacking path:** `src/resolved_programs.R` / `TARIFF_RESOLVED_STACKING` is OFF by default and is *not* implicated in any of these — all confirmed bugs are on the default production path.
- **Baseline is unaffected by every confirmed bug** — they are dormant until a scenario uses `set_rate` on a 232 heading or `add_program`. This is the whole reason the byte-identical gate didn't catch them, and the reason a calculator-output scenario test harness is the right systemic fix.
