# Ship-of-Theseus refactor: a spec-driven calculator (Pass 1)

> Durable in-repo copy of the plan-mode plan (`swirling-moseying-coral`), lightly
> reconciled with decisions pinned at execution time. This is the canonical copy
> on branch `theseus`; the planks below carry a **Status** line, updated as each lands.

## Context

The AuthoritySpec layer is the right abstraction and is already live and always-on,
but it is **hollow**: the `rate` field is a verbatim blob behind a sentinel
(`rate$resolved`), and the calculator unpacks it back into bespoke per-authority
locals and runs a ~3,000-line branching body. Three dimensions are "declared but
not obeyed" — **rate**, **stacking**, **timing**. The goal is to incrementally
relocate policy from hardcoded calculator logic into the spec, one parity-gated
plank at a time, until the calculator is a generic engine that *reads* the spec.

Investigation established: the parser is **not** the problem (0 dropped programs
across 43 revisions; only a bounded ~4% non-ad-valorem leak), and there is **no
rewrite justified** — the debt is localized to one file and one pattern. Full
taxonomy of parameter types in `docs/tariff_parameter_taxonomy.md`.

**This plan is Pass 1 only** (the parity-safe relocations). Pass 2 (correctness
fixes that change numbers and need an oracle) is specified in the appendix for the
future, but is **not** in scope now.

## Design decisions (locked with John)

1. **Scope:** Pass 1 only; Pass 2 documented in detail for later.
2. **Workflow:** one long-lived branch (`theseus`), **no PRs** — we just increment
   commits on this branch. (Cut off `9f9837d` on `feat/counterfactual-pharma-301cs`.)
3. **Parity bar:** numeric tolerance per column class (rates vs shares vs weighted ETR),
   NOT byte-identity — refactors reorder float ops.
4. **IEEPA:** done **late** in Pass 1, after the easy authorities prove the loop.
5. **Rate field:** **compositional layers** — `{default, by_country, overrides,
   by_product_tier, default_unlisted_rate, target_total, rate_type}`. Precedence
   `overrides > by_product_tier > by_country > default_unlisted_rate > default >
   target_total`, **parity-locked to current behavior, not invented** (derived from
   `06_calculate_rates.R`). `default_unlisted` is an accepted alias of
   `default_unlisted_rate`.
6. **Floors:** **named modes** in `rate_type` — `floor_static` (232 deals: compute
   once vs the **original** base) and `floor_post_mfn` (IEEPA-recip / Annex-3:
   recompute vs the **post-MFN** base). Both share the math `pmax(0, value − base)`;
   they differ only in *which* base the caller supplies. Plus `surcharge`, `passthrough`.
7. **rate API — descriptor + helper (decision made at execution).** `resolve_rate()`
   is a **pure reader** returning a descriptor `{value, rate_type, floor_base, matched}`;
   a sibling `apply_rate_semantics(value, rate_type, base)` does the surcharge/floor/
   passthrough math. `floor_base ∈ {original, post_mfn}` tells the calculator which
   base to pass — so floor-timing lives where the base values are.
8. **Mixed statutory×adjustment rates** (semiconductor, auto rebate, subdivision-r):
   **leave the blend as a calculator step**; structure only the clean statutory layers.
   Do not pull shares into the spec in Pass 1.
9. **`resolved_programs.R`:** **delete & rebuild** the intermediate table fresh as part
   of the stacking plank (it has drifted — references an orphan `section_301_cs`).
10. **Dual signature retired EARLY — Plank 7 pulled forward of 4b (decided with John,
    2026-06-05, option "b").** The no-fallbacks directive (4c) is now **standing**.
    Sequence: retire the specs-less branch of `calculate_rates_for_revision()` FIRST,
    THEN write 4b spec-only (`stop()` if no spec, like 4c) on the clean single-signature
    engine. Production already passes specs (`00:138`, `09:1376`), so the specs-less
    branch is dead there. **Scoped by the `plank7-4b-lockdown` workflow (2026-06-05):**
    the ONLY live specs-less caller is the single `run_tests_daily_series.R:972/985`
    Test-16 block (policy-vs-HTS IEEPA-invalidation). `test_rate_calculation.R` is NOT a
    caller — it never invokes the calc (only a header comment at `:6`); its Russia-§232
    invariants (`:856/872/908`) are `readRDS(snapshot_2026_rev_5.rds)` reads of the frozen
    golden, blind to the signature and unchanged by Plank 7. **The one load-bearing edit:**
    Test-16 must build a DISTINCT spec per half (`pp_policy` vs `pp_hts`) via `.specs_for_calc`
    — reusing one spec erases the invalidation-date divergence the test checks. Everything
    else is mechanical (trim 3 redundant overwritten args + delete dead branches). Parity:
    production behavior is unchanged → a rebuild is byte-identical; gate = unit suites +
    one cheap parity tripwire, not a full 43-rev array.

## Target end-state (the dream — reached at the end of Pass 1)

Parser+config emit a complete spec (rate field real, no blobs); the calculator reads
`scope × rate × semantics × stacking` off the spec with only irreducible conditionals;
counterfactuals mutate any dimension incl. IEEPA via a complete verb vocabulary; output
bit-identical-within-tolerance throughout. (Unified timeline + correctness fixes are Pass 2.)

## Branch & workflow

`theseus`, cut off `9f9837d`. All planks accumulate here; **no PRs, no merge** — John
runs the parity gate live (the worktree lacks the gitignored build data). Compute runs
via `sbatch`, never the login node.

## Pass 1 planks (in order)

**Plank 0 — keystone: real compositional rate schema.** — ✅ **DONE** (verified, this branch).
In `src/authority_spec.R`: the `rate` sub-schema (decision 5/6), `resolve_rate()` (the
precedence reader → descriptor) + `apply_rate_semantics()` (the four `rate_type`
semantics, incl. both floor modes), and `validate_rate()` wired into
`validate_authority_spec()`. No calculator change → parity trivially holds. Key
property: the live adapter still parks the real object in `rate$resolved` and fills
the layer names with **sentinel strings** (`from_raw`/`from_list`/
`from_products_base_rate`); the reader + validator treat those as **hollow/absent**, so
existing specs resolve to nothing here and validate unchanged. Tests:
`tests/test_resolve_rate.R` (63 assertions: precedence, both override forms, both floor
modes, hollow-sentinel tolerance, a partial-match regression guard) + the existing
`test_authority_spec.R` (19) and `test_authority_adapter.R` (20, builds the real spec
set end-to-end) still green. Gate: `sbatch scripts/submit_resolve_rate_tests.sh`.
Notable: `overrides` supports **two element forms** — a named scalar `'4120' = 0.25`
(product→rate, any country, the existing convention) and an entry list
`list(products=, countries=(opt), rate=)` (the rich product×country deal form for 4a).

**Plank 1 — Section 301 (prove the loop).** — ✅ **DONE** (parity GREEN: 47/47 artifacts
within tolerance vs tests/golden/9f9837d, full 43-rev recompute, job 13789634).
Adapter `build_s301_additive_tier()` resolves the additive hts8→rate tier (date-gated via
`filter_active_ch99`, suspended-drop, `max()` supersession) into `section_301`'s
`by_product_tier`; the BUILD reads it back via the spec instead of recomputing inline.
country_scope was already spec-driven. `validate_rate` gained the `flat` key (latent
Plank-0 gap: `add_program` uses it).
  - **Plan reconciliation (the line-refs were stale):** stacking.R is already class-based
    (301 = `additive`; no `country==china` branch left — the only former hardcode is
    `additive_countries=cty_china` on *fentanyl*, already data). So Plank 1's real lift was
    the **rate**, not branch deletion.
  - **Fallbacks RETAINED, not deleted:** `test_tpc_comparison` + `run_tests_daily_series`
    call `calculate_rates_for_revision()` **without specs**, so the inline 301 compute +
    `CTY_CHINA` scope must stay until those callers go away. The literal deletion is
    correctly coupled to **Plank 7 (drop the dual signature)**. The build itself is now
    spec-driven (proven by the gate). cs (content-split) 301 flavor left inline — dormant
    in baseline, parity-safe.
  - Adversarial review confirmed the adapter tier == inline tier bit-for-bit (a–g SAFE).

**Plank 2 — Section 201.** — ✅ **DONE** (parity trivially GREEN — see reconciliation; no
rebuild). `section_201`'s `country_scope = {include: all, exclude: Canada}` is in the adapter
and the calculator reads it (`06:` "Plank 2" hook → `resolve_country_scope`); 201 is registered
`SCOPE_DRIVEN` in `scenario_ops.R`, so `set_country_scope`/`set_active`/`disable` all drive it.
Scenario unit tests added for 201 rescope + disable (`tests/test_scenario_ops.R`, mirroring 301).
Gate: `sbatch scripts/submit_plank2_tests.sh` (scenario_ops + spec + adapter; pure-logic, no build data).
  - **Plan reconciliation (the substance pre-landed under "Phase 2e"):** the 301cs branch already
    relocated the 201 scope into the spec + wired the calc read, and that code is **present at
    `9f9837d`** — i.e. in the golden. `resolve_country_scope({all, exclude: Canada})` is
    `setdiff(countries, Canada)` **bit-for-bit**, so the candidate == golden with no number change;
    a 43-rev rebuild would be a guaranteed no-op (skipped to preserve cluster time). Plank 2's real
    remaining lift was the **scenario-test coverage gap** (the test baseline carried a 201 spec but
    never asserted a 201 op) + this reconciliation.
  - **Fallback RETAINED, not deleted** (same as Plank 1): `test_tpc_comparison` + `run_tests_daily_series`
    call `calculate_rates_for_revision()` **without specs**, hitting the `else setdiff(countries, Canada)`
    path. The literal deletion is coupled to **Plank 7 (drop the dual signature)**; the `06:` hook now
    says so.
  - **"`disable:` vocab in `policy_params.yaml`" reconciled:** there is **no** `disable:` key in the yaml.
    The disable vocab lives in `scenario_ops.R::SCOPE_DRIVEN_AUTHORITIES` (already includes
    `section_201`) + `op_disable`. The plan line anticipated a yaml location the live code doesn't use.

**Plank 3 — Section 122.** — ✅ **DONE** (parity GREEN: 47/47 artifacts within tolerance vs
tests/golden/9f9837d — full 43-rev recompute, parity job 13797778 + snapshot-only 13798477).
De-blobbed: the s122 blanket rate moved from the opaque `rate$resolved` blob `{s122_rate,
has_s122}` into the structured compositional `rate$default` layer (`rate_type='surcharge'`).
The calc READS it via `resolve_rate(...)$value` and gates on `value > 0` — bit-exact with the
old `has_s122 ≡ rate>0`. scenario_ops gained a `DEFAULT_RATE_AUTHORITIES` category (`set_rate`
→ `rate$default`, `disable` → 0); section_232 stays the resolved-blob `RATE_DRIVEN` path until
Plank 4a. Dropped the dead `s122_rates_from_specs` accessor. Gates: `sbatch
scripts/submit_plank3_units.sh` (47+19+21 assertions) + `scripts/submit_plank3_parity.sh`.
  - **Not a close-out (unlike Plank 2):** s122's rate was already spec-driven but as a BLOB, not
    a structured layer. Per John — *no half-measures; the premise is to de-blob fully* — this did
    the real structural migration. This is the **template for the remaining blob authorities**
    (s232 = 4a, IEEPA = 4b): blob → structured layer; calc reads via `resolve_rate`; scenario_ops
    mutates the structured field; parity rebuild confirms bit-exact.
  - **Fallback RETAINED** (Plank 1/2 precedent): the specs-less `else extract_section122_rates`
    serves the dual-signature callers (test_tpc_comparison, run_tests_daily_series); deletion is
    coupled to **Plank 7**. The `06:` hook says so. No `--no-config-check` needed (policy_params.yaml
    untouched → hashes to the golden manifest).

**Plank 4 — the bulk (per authority).**
- **4a — Section 232** (multi-program): structure each of the **7** programs' rate
  (`default` + country deals as `overrides` + named floor modes). **Leave**
  semiconductor/auto-rebate/subdivision-r/derivative blends as calc steps (decision 8).
  Delete the UK deal hardcode (`06:2134-2145`); model Taiwan aircraft as a scope (`06:2964-2995`).
  - **Read-path = FULL REPOINT (decided with John, 2026-06-05).** The calc reads §232 via
    `resolve_rate()` directly at all ~36 read sites — NO reassembled `s232_rates` shim. Matches
    the s122 "calc reads the spec" contract literally (John's "no half-measures" call); accepts
    the larger diff + higher parity risk over the low-risk shim.
  - **KEY: the s122 `value>0` gate does NOT transfer.** `has_232` is a **12-term OR-gate**
    (`.s232_recompute_has_232`, scenario_ops.R:69-75) — ORs `auto_has_deals` (TRUE even at
    `auto_rate=0`) + both derivative rates + `wood_rate||wood_furniture_rate`. NOT reducible to
    "any program rate > 0"; keep the explicit gate.
  - **7 spec programs** (`authority_adapter.R:127-141`): steel/aluminum/copper (metal) +
    autos/mhd/wood/semiconductors (full). `pharmaceuticals` = dormant 8th `set_rate` name
    (S1b adds a dormant program for it). `wood` = one program, two rate fields.
  - **Staging = 4 commits, finer S1 (decided with John).** Full-repoint dropped the
    trivial-bit-exact S1 (scalars are entangled with the shared `has_232` gate), so S1 was split
    to isolate the gate risk. Each = commit + full parallel-array parity gate vs `9f9837d`:
    - **S1a ✅ DONE — parity GREEN 47/47** (commit `2a2232e`). blanket steel/aluminum/auto BASE reads
      (`06:1600-1602`) → `rate$default`. Helper `s232_spec_rate(specs, s232_rates, program_id, blob_field)`
      reads `resolve_rate(prog$rate)$value`, falls back to the blob scalar for the specs-less callers (Plank 7).
    - **S1b ✅ DONE — parity GREEN 47/47** (commit `307401b`). heading programs (copper/mhd/wood/semi) +
      a dormant `pharmaceuticals` program get `rate$default`; `compute_heading_gates`/`resolve_heading_rate`/
      `.s232_recompute_has_232` repointed to read program rates off the spec (heading→program-id via the new
      `HEADING_RESOLVED_PROGRAM` map). The non-rate gate inputs (`auto_has_deals`/`auto_has_parts`,
      `wood_furniture_rate`, derivatives) stay on the residual blob. Unit: adapter 31/31, scenario_ops 48/48.
    - **S2 ✅ DONE (parity GREEN 47/47 — 2 commits, 2026-06-05)** — country deals/overrides/exempts de-blobbed.
      **Commit 1 (blanket, `f59581c`)**: steel/aluminum exempt + metal HTS overrides + config exemptions → ONE
      merged `rate$by_country` (NOT `overrides` — a per-country read is `resolve_rate(product=NULL)`, which SKIPS
      both override forms; corrected the stale plan framing). Parity GREEN, 0 violations (array `13816297`).
      **Commit 2 (deals, `6358990`)**: deals split by CONCEPT (John's call) — `overrides` (flat product×country,
      scope-label form) + a NEW `floors` field; the calc expands the scope label to HTS at run time and keeps
      the floor/surcharge math (decision 8; floors = `floor_static` vs ORIGINAL base). The ONLY Plank-0 touch =
      an additive `validate_rate` extension (scope-form + `floors`); `resolve_rate` untouched. Parity GREEN
      47/47, 0 violations (array `13817257`). `auto_exempt` + the deal-gate flags stay on the residual blob → S3.
    - **S3 ✅ DONE (Plank 4a close-out).** UK annex deal + Taiwan aircraft exemption STAY for now; residual blob is
      at its decision-8 floor (8 gate/derivative fields stay). The only code change = removing the verified-dead
      `auto_exempt` calc read. **PLANK 4a CLOSED.** NOTE (John, 2026-06-05): the annex tier RATES + UK deal ARE
      spec-expressible (`by_product_tier`/`overrides`, no new axis) — deferred as the parity-safe **Plank 4c**, not
      because the spec can't hold them. Taiwan stays genuinely (provenance + column-null). See "S3 — LOCKED + DONE"
      + the Plank 4c section below.
  - **Gate-tooling fix landed (commit `134759f`, src/parity.R):** the `--unweighted` build drops the
    un-gated weighted/ETR columns (`weighted_etr*`, `etr_*`, `*_imports_b`) the golden carries; the
    comparator now skips golden-only columns matching `^weighted_etr|^etr_|_imports_b$` instead of
    false-flagging them. Without this, every 4a daily gate false-fails post-gather-refactor.
  - **DEFER to Plank 5:** metal/stacking shells + the 4-copy metal-chapter→type map (`stacking.R:83`,
    `06:555/2061/2159` — copies already disagree on copper). 4a leaves them.

#### Plank 4a — execution notes & handoff (as of S1b green, 2026-06-05)

> Written for a fresh instance picking up at **S2**. Read this + the Progress log before touching code.

**Architecture as actually built (the full-repoint pattern — reuse it for S2/S3):**
- **`s232_spec_rate(specs, s232_rates, program_id, blob_field)`** (`06_calculate_rates.R`, just after
  `resolve_heading_rate`) is the central read helper. Spec present → `resolve_rate(program$rate)$value`
  (the de-blobbed `rate$default`, incl. 0 — NA only when truly absent → then blob fallback). Specs-less
  dual-signature callers (`test_tpc_comparison`, `run_tests_daily_series`) → the blob scalar. **Retain the
  blob fallback until Plank 7.** Every new S2 read should go through this same spec-first/blob-fallback shape.
- **The residual blob shrinks per stage** and rides on `programs[[1]]` (steel) `$rate$resolved`, read by
  `s232_rates_from_specs(specs)`. After S1a+S1b it still holds: exempt lists, `*_country_overrides`,
  `auto_deal_rates`/`wood_deal_rates`, derivatives, `auto_has_deals`/`auto_has_parts`, `wood_furniture_rate`,
  `has_232`. **S2 drains the deals/overrides/exempts; S3 drains the rest (derivatives stay per decision 8).**
- **`has_232` stays a residual field**, recomputed by `.s232_recompute_has_232(spec)` which reads the 8
  program `rate$default`s off the spec + the residual non-rate terms. **Keep the THREE has_232 formulas in
  lockstep:** `extract_section232_rates` (parser baseline), `compute_heading_gates` (calc), and
  `.s232_recompute_has_232` (scenario_ops). The s122 `value>0` substitution does NOT apply here.
- **scenario_ops:** §232 `set_rate`/`disable` mutate each program's `rate$default` (via `.find_program_index`)
  and recompute `has_232` from the spec; `set_exempt` still writes the residual exempt lists (S2 moves it).
  The scenario behavior is validated by `tests/test_scenario_ops.R` (unit), **NOT** by the parity gate.

**Gate mechanics — learned the hard way (do not relearn):**
- **The build sources LIVE `src/*.R` at task runtime.** NEVER edit live source while a parity build for
  another stage is in flight — late/retried array tasks will compile the half-edited file and silently
  poison the gate. **Workflow that works:** develop the next stage in a git worktree (`git worktree add -b
  <stage>-dev ../trt-<stage> HEAD`), unit-test there (pure-logic tests need no build data), and
  `git cherry-pick` onto `theseus` only once the prior stage's build has finished. (`trt-s1b` on branch
  `s1b-dev` exists and can be reused.)
- **Parity is baseline-only** (empty ops): it validates that the read-repoint is bit-exact, NOT the scenario
  mutations. Each stage is bit-exact *by construction* — `rate$default` holds the same scalar the old blob
  read returned, and `resolve_rate` returns it verbatim. If a stage's gate is RED, a real number moved.
- **Run R via** `module load R/4.4.2-gfbf-2024a` (Rscript isn't on the bare PATH). Pure-logic unit tests run
  fine in the interactive alloc; heavy builds go through Slurm.
- **Gate commands (the live 2-step, ~18 min):**
  1. `GATHER_ARGS="--unweighted" bash scripts/submit_build_array.sh` → array (one task/rev) + `afterok` gather.
  2. once gather done: `GOLDEN=tests/golden/9f9837d sbatch scripts/submit_plank3_parity.sh` (generic; reusable
     for every stage). Verdict in `output/parity_results_<ts>/` + the summary slurm log (`47 passed / 0 failed`
     = GREEN). No `--no-config-check` needed unless a stage edits `config/policy_params.yaml`.

**S2 LOCKED DESIGN (2026-06-05).** Settled via a fan-out workflow (5 mappers → architecture decision →
per-slice adversarial parity verdicts) + two decisions from John. The adversarial pass verified the 3 blanket
slices parity-safe (high confidence) and caught two real blockers in the deals slice (below). **4 separately-
gated sub-commits, cheapest→riskiest:**

1. **HTS metal overrides** (`steel_country_overrides`/`aluminum_country_overrides`, calc `06:1665-1678`) →
   `by_country` on the steel/aluminum programs. Cleanest: parser already census-keys + EU-expands + `max()`-
   collapses these (`05:625-661`), so the adapter copies them straight in. Do FIRST to prove the
   `by_country`-over-`default` plumbing.
2. **Exempt lists** (`steel_exempt`/`aluminum_exempt`, calc `06:1657-1662`) → `by_country = 0` entries, MERGED
   OVER slice 1 (exempt runs *before* the override loop, so the override must win → in a flat `by_country` map
   that means write exempt-zeros first, then overrides). Adapter must **census-expand each ISO/EU token via the
   same three paths `is_232_exempt` uses** (identity-census, `ISO_TO_CENSUS[iso]`, `EU→EU27_CODES`), because the
   blob keys are ISO/EU-tokens, not census. **Baseline is parity-trivial here** (the `*_exempt` lists are EMPTY
   in the golden — steel/alum resolve via the increase branches), so the risk is the WRITE path, not the read.
   **Leave `auto_exempt` on the blob** — `auto_rate` never sets `rate_232` (autos flow through the heading path),
   so `auto_exempt`'s only effect is `s232_country_codes` membership, swamped by the heading-present union; zero
   parity benefit, real edge-case risk.
3. **Config exemptions** (`S232_COUNTRY_EXEMPTIONS`, calc `06:1685-1700`) → `by_country` on steel/aluminum,
   MERGED OVER slices 1+2 (config runs last → wins). Source is `pp$S232_COUNTRY_EXEMPTIONS` (config, already
   census + EU27-expanded). The adapter is per-revision, so it **pre-resolves the date gate** `is.null(expiry) ||
   rev_date < expiry` (**strict `<`**) and bakes only the active entries. The Russia entry (rate=2.0, expiry NULL,
   permanent) flows through here — it is the last config entry, NOT a separate field, and is IN scope. (Distinct
   from the annex-era Russia surcharge at `06:2207-2264`, which reads `annex_cfg`/config, NOT the blob → OUT of S2.)
4. **Auto + wood deals** (calc `06:1882-1989`) — **THE RISKY SLICE.** Split by CONCEPT (John's call), each as a
   structured field the CALC reads (NOT `resolve_rate`), carrying a product **scope label** the calc expands at
   run time (so products stay calc-time → no new parity surface):
   - **flat product×country overrides** (the surcharge deals: UK vehicles 7.5%, UK wood 10%) → `overrides`
     entries in **scope form** `{scope, countries, rate}` (e.g. `scope = 'vehicles'`). These have NO `products`
     key, so `resolve_rate` auto-skips them (`hit_p` requires products → always FALSE) → reader-invisible by
     construction; the calc reads them by scope.
   - **floors** (EU/JP/KR vehicle 15%, UK parts 10%, EU/JP/KR wood 15%) → a NEW `floors` field, entries
     `{scope, countries, floor}`; the calc applies `pmax(floor − base, 0)` against the ORIGINAL pre-232 MFN base
     (`floor_static` / `floor_base='original'` — the #1 parity risk; do NOT "fix" to post-MFN, Pass-2 concern).
   - The adapter **census-expands each deal's ISO/EU country at build time** (mirroring `iso_to_census_vec`:
     `EU → names(pp$eu27_codes)` = 27 codes unversioned; ISO → `ISO_TO_CENSUS`), and tags each entry with the
     deal's `program` as the scope label. Surcharge entries flat-REPLACE `rate_232`; floors `pmax`. No
     product×country cell is double-hit (vehicles/parts disjoint; wood once-per-country), so order is preserved
     but non-observable.

**THE ONLY Plank-0 touch in S2 — additive `validate_rate` extension (deals slice only):** (a) accept the
`{scope, countries, rate}` form on `overrides` entries (today `validate_rate:333` requires non-empty `products`);
(b) whitelist a `floors` key + a light shape check (mirrors the overrides-entry check but with `floor` instead of
`rate`). Both are additive and parity-safe — no existing spec uses scope-form or floors; existing callers
unchanged; `resolve_rate` is NOT modified (scope/floors entries are inherently reader-invisible). This is the
small validator addition, NOT the rejected "per-entry rate_type in resolve_rate" keystone change.

**scenario_ops obligations (move write-path with read-path, per slice — do NOT split across commits):**
- **Exempt slice:** `op_set_exempt` (steel/aluminum) must write the `by_country = 0` entry instead of the residual
  blob `*_exempt` field, AND census-expand ISO/EU at write time (the old path expanded at READ via `is_232_exempt`;
  the new path must expand at write or the exemption silently no-ops). The existing test asserting set_exempt
  writes the blob (`tests/test_scenario_ops.R:~162-164`) must be **rewritten** to assert `by_country`.
- **Deals slice:** `op_disable` ALREADY drains the deal tibbles (`scenario_ops.R:217-219`) — it must be repointed
  to clear the new `overrides`(scope)/`floors` fields in lockstep, or `disable(section_232)` silently stops
  draining deals. (The deals design's "no scenario op touches deals" was FALSE — adversarial catch.)
- **has_232 stays a residual gate** in ALL slices (no program added/removed → the three formulas stay in
  lockstep untouched). `auto_has_deals`/`auto_has_parts`/`wood_furniture_rate`/derivatives stay on the blob (S3 /
  decision-8). `extract_section232_rates` (parser) is unchanged — the adapter re-packages its output, as in S1a/S1b.

**Gate-red protocol:** a red gate means a re-packaging detail drifted (application/merge order, census/EU
expansion, strict-`<` boundary, or the floor base regressed to post-MFN) — re-derive the detail; do NOT reach for
a schema change. Before gating the deals slice, hand-re-derive the floor math on UK auto parts (floor 0.10), EU
auto vehicles (floor 0.15), UK wood (surcharge 0.10) vs the golden snapshot.

**S3 — LOCKED + DONE (2026-06-05, Plank 4a CLOSE-OUT).** A focused lock-in workflow (3 analyses + adversarial
decision, run `wf_0ccdd059-752`, output `tasks/w0mr1sy1d.output`) settled that **S3 has no parity-safe de-blobbing
left** — it is a close-out, not a de-blob. Stress-tested verdicts:
- **UK annex deal** (`06:~2235-2246`): **STAYS FOR NOW (deferred, NOT impossible — see Plank 4c).** It applies
  `annex_1a → uk_rate 0.25`, `annex_1b → 0.15` on UK steel/aluminum, and the annex tier `case_when` (`06:~2204-2211`)
  overwrites the pre-annex S2 `by_country` UK override BEFORE the deal, so the deal — not by_country — is what
  reaches the panel in annex-era revisions; deleting it drops UK to the generic tier (0.50/0.25) → breaks parity.
  **CORRECTION (John, 2026-06-05):** the earlier claim that "no spec layer can return 0.25-or-0.15-by-tier" was
  WRONG. Each product is in exactly ONE annex tier, so `product×country → rate` is single-valued — the UK deal maps
  cleanly onto the existing `overrides` layer (UK × {annex_1a products}→0.25, × {annex_1b products}→0.15), and the
  generic tiers onto `by_product_tier`; `overrides > by_product_tier` precedence does the rest. NO new resolver axis
  is needed. It STAYS in S3 only because relocating it means moving the annex CLASSIFICATION (CSV match + inference)
  to the adapter and is cleanest done with the whole annex regime as a unit — a parity-SAFE de-blob captured as
  **Plank 4c** below. (Values are already config-driven in `policy_params.yaml section_232_annexes`, not the blob.)
- **Taiwan civil-aircraft exemption** (`06:~3074-3096`): **MUST STAY-AS-IS.** A spec `scope=0` cannot reproduce it:
  it gates on `!is.na(s232_annex)` (metals-annex provenance — a context the spec lacks) AND nulls the `s232_annex`
  column (a spec rate can add a value, never null a calc column). Verified hazard: 3 hts8 are in BOTH auto-parts
  and MHD heading lists and keep their heading rate (0.25) while carrying `s232_annex=annex_1b`; a naive scope=0
  keyed on (product∈TW-list, country=TW) coincides numerically today but would silently zero non-metals 232 the
  instant a heading rate moves off annex_1b. Already maximally data-driven (config flag + country + resource-file
  product list). Stays as a contained post-calc gate.
- **Residual blob** (`programs[[1]]$rate$resolved`): **8 fields STAY, 1 is a no-op.** `has_232` + its non-rate gate
  inputs (`auto_has_deals`, `auto_has_parts`, `wood_furniture_rate`) STAY (3-formula lockstep); the 4 derivative
  fields STAY (decision 8). `auto_exempt` is a verified NO-OP (`auto_rate` never set `rate_232`; the only consumer,
  the `auto_rate>0` filter term, was fully subsumed by the heading-present country union) → its dead calc READ was
  removed in the S3 commit (the field stays in the parser return for the independent `generate_etrs_config.R` path).
- **S3 commit = the `auto_exempt` dead-read removal (verified no-op) + this close-out doc.** Gate: full 43-rev array
  (the close-out gate for Plank 4a) — bit-exact expected by construction.
- **DEFERRED (explicit boundary, not a gap) — see Plank 4c:** de-blobbing the §232 ANNEX REGIME rates into the spec.
  This is **parity-SAFE** (a relocation, no number change → no oracle needed; NOT a Pass-2 behavior-change item) and
  needs **no new resolver axis** — the flat tiers go in `by_product_tier`, the UK deal in `overrides`, the annex_3
  floor in the S2 `floors` layer. The deferred work is relocating the annex CLASSIFICATION (CSV prefix-match +
  unmatched-product inference, ~150 lines) to the adapter and doing it as a coherent unit. The non-flat rules
  (country surcharges, subdivision-r) stay per decision 8; the Taiwan exemption stays genuinely (provenance +
  column-null). John flagged this 2026-06-05 to revisit — full spec + slicing in the **Plank 4c** section.

**With S3, PLANK 4a IS CLOSED** — §232 is an 8-program spec; the clean statutory layers (default/by_country/
overrides/floors) are de-blobbed and read via `resolve_rate` + `s232_deal_records`. What remains on the blob is
exactly the decision-8 designed endpoint (gate inputs + derivative blends), not debt.
- **4b — IEEPA reciprocal + fentanyl (LATE, the big rock):** structure `by_country` +
  `default_unlisted_rate` (universal baseline) + `rate_type` (surcharge/floor_post_mfn/
  passthrough) + floor-exempt set. Relocate CA/MX exemption (`06:~1090`), floor-country
  groups (`06:~1020`), phase supersession (`06:~973-1008`) into data; wire the already-
  declared China-fentanyl `stacking.exceptions` so `stacking.R:~145` stops branching.
  IEEPA invalidation stays `active.until` (already wired).
  - **The 4 design decisions — DELEGATED to Claude, then John settled the DIRECTION (2026-06-05):
    make IEEPA FULLY spec-driven + elegant ("I want everything to be elegant"), NOT lean.** The
    earlier "IEEPA is repealed" point does NOT conflict — it only removed the *scenario-value*
    justification for the work, but elegance/uniformity is its own justification (a generic engine
    with no IEEPA-specific wart pays off in clarity + maintainability regardless), and the flexibility
    then rides along for free. So we do the full de-blob. **What "elegant" means here (the target, so
    we don't over-reach): the spec holds all the DATA + declarative TAGS; the calculator is a GENERIC
    engine that reads them — NOT cramming pipeline-ordered logic into a data structure.** Locked:**
    1. **Country-EO two-term surcharge → express the components as spec DATA** (the two rate
       components + their two exempt-set refs), combined by a GENERIC calc step (not an IEEPA-special
       branch). Exact elegant shape = design-pass call.
    2. **Per-country `rate_type` → PROMOTE to the schema** (the §232-annex pattern: tag in spec
       [China=surcharge, EU/JP/KR/Swiss=floor], generic `apply_rate_semantics` math in the engine).
       The schema extension 4b adds; touches `validate_rate`, NOT `resolve_rate` precedence.
    3. **CA/MX universal-baseline exclusion → reuse `country_scope`** (§201 pattern) if the
       `default_unlisted` complement honors scope; else `default_unlisted_exclude`.
    4. **Floor-exempt country-group membership → promote to the spec** (membership as data; the
       masking stays a generic calc primitive).
  - **Net scope = FULL/elegant de-blob:** by_country rates + `default_unlisted` baseline + per-country
    `rate_type` tags + the EO components + floor rates + phase structure + exempt/floor-exempt sets all
    become spec DATA. The genuinely procedural bits — the two-stage `floor_post_mfn` recompute (tied to
    the stacking order: floored vs the POST-MFN base, `06:1298` + `06:~2738`) and the phase-supersession
    collapse (replace-then-SUM) — STAY calc functions, but rewritten as GENERIC, reusable primitives
    that READ the spec, NOT IEEPA-special code (the same line §232 draws: annex-3 floor math is a
    generic engine step, only the floor rate is data). End state: zero IEEPA-specific branching in the
    engine; everything declarative in the spec.
  - **Honest cost (eyes open): higher effort + higher parity risk than lean.** The one real landmine
    is the floor — a two-pass recompute against the POST-MFN base (known only mid-pipeline), so
    de-blobbing it is where a number can silently move; the floor slice may need a gate cycle or two.
    STAGE 4b so that risk is isolated + caught early. Parity TRAPS: two-stage floor; phase supersession
    (replace-then-SUM, not max); CA/MX complement-skip; MAX-per-census on fentanyl general rates. Slice
    S-style; adversarially re-derive Brazil (50%) + a floor country vs the golden before each gate.

**Plank 5 — stacking generalization.** — ✅ **DONE / CLOSED — parity GREEN 47/47** (array
`13867594` → gather `13867595` → parity array `13867821` → summary `13867822`: 47 passed / 0
failed, ALL ARTIFACTS WITHIN TOLERANCE vs `tests/golden/9f9837d`). **This was the last Pass-1
plank — PASS-1 IS COMPLETE.**
Mapped + adversarially verified first (workflow `wf_2322681a-b45`, 10 agents) — which
**reframed the plan**: the stacking MATH was ALREADY generic (Phase-3a: `apply_stacking_rules` /
`compute_net_authority_contributions` read a `policy` data structure via
`compute_stacking_contributions`; NO literal country/232 branches remained), so the real lift
was building that policy FROM the spec, not de-branching. Slices:
- **5a — metal-chapter→type map dedup** (commit `9c54673`). The map was already config-backed via
  `cc$STEEL_CHAPTERS`/`ALUM_CHAPTERS` (`policy_params.R:236`, from `pp$section_232_chapters`); 5a
  added a `copper` sibling + `cc$COPPER_CHAPTERS` and repointed the live redundant literals
  (`authority_adapter.R` uk_chap/prim_by_type/a1a_ch). The config-absent fallback literals
  (`data_loaders.R` defaults, `06:630` else) stay as the established house pattern. Kept
  `metal_content.primary_chapters` (copper-excluded) DISTINCT. Parity-safe by value-identical
  substitution (`tests/test_metal_chapters.R` 7/7).
- **5b — build the stacking policy from the spec** (commit `d63d3bf`, THE core). New
  `stacking_policy_from_specs(specs, cty_china)` (skeleton-override design: fixed skeleton supplies
  the load-bearing order + rate_col↔net mapping + the spec-less `rate_301_cs`; only `class` +
  `additive_countries` come from the spec; `primary_metal`/`primary_full`→`primary`; `mfn` excluded).
  Routed through the SINGLE calc site `06:2820` (NOT `06:197` — that's `calculate_rates_fast`, no specs,
  recomputed at step 8). Parity-safe by construction: `identical(stacking_policy_from_specs(baseline_specs),
  default_stacking_policy())` holds byte-for-byte (`tests/test_policy_from_specs.R` 13/13, incl. the
  counterfactual that mutating a spec class flows into the policy).
- **5c — resolved_programs.R disposition: UNIFY, not delete** (commit `0181e8c`). **DEVIATES from
  decision 9's literal "delete & rebuild"** — that rationale ("drifted: orphan section_301_cs") is now
  STALE (both `RESOLVED_AUTHORITIES` and `default_stacking_policy` carry `rate_301_cs`), and the file is
  the documented Wire-2 / counterfactual stacking substrate. Kept it; removed the real drift surface
  (dropped the hand-maintained `precedence` column, derive it from policy order via `seq_along`); threaded
  the spec-derived policy into the flag-off resolved branch (`06:2818`). **Also fixed a latent pre-existing
  crash**: `build_resolved_programs` lacked a `rate_301_cs` guard (added to `default_stacking_policy` in
  Phase 3a but never covered) → it errored on any frame missing that column, so `tests/test_resolved_programs.R`
  was silently failing on HEAD. Inject 0 for any missing policy rate_col (mirrors the wide path). Test
  updated to the 8-authority reality (12/12). *John can override the UNIFY call — it's revertible.*
- **5d — `set_stacking` scenario verb** (commit `428ef3c`). Mutates an authority's/program's
  `stacking{class,exceptions}` (now load-bearing via 5b). Mirrors `op_set_active` (modifyList merge); class
  validated by the existing `validate_spec_set` pass. Closes the "no set_stacking op" gap from
  `counterfactual_generality_ground_truth.md`. Parity-trivial (baseline = empty ops; scenario_ops-only →
  no rebuild). Honest boundary documented: flows through the calc (06) only — the 09 daily re-stack is
  specs-less (default fallback), so a set_stacking counterfactual is NOT seen by a daily re-aggregation that
  bypasses 06 (Pass-2). Unit: `tests/test_scenario_ops.R` 71/71 (+10).

Gate: 5a+5b are the build-path changes (43-rev array confirmed byte-identity; 5b dominated the risk, pinned
by the `identical()` unit invariant). 5c (flag-off) + 5d (scenario-only) are off the gated path. **Gate GREEN
47/47 → Plank 5 CLOSED, Pass-1 COMPLETE.** The calculator now reads `scope × rate × semantics × stacking` off
the spec; the only remaining residuals are the decision-8 §232 blends/gates (intended) and the Pass-2 items
below. Open for John (revertible): the 5c UNIFY-vs-DELETE call; threading the spec/policy into the 09 daily
re-stack so a `set_stacking` counterfactual survives a daily re-aggregation (Pass-2, doesn't affect parity).

**Plank 6 — IEEPA scenario verbs.** — ✅ **DONE** (commit `7318eff`, unit-green; parity-trivial — no rebuild, Plank 1/2 precedent). Now that 4b structured the IEEPA rate, `scenario_ops.R` mutates it: `set_rate` (per-country: `op$country` → `by_country[c]`; reciprocal = clean flat surcharge, drops the EO two-term), `set_country_scope` (`exclude` drops countries → 0 + bars reciprocal baseline; `include={set}` restricts + baseline off), `disable` (clears every rate layer → calc gate OFF). New `IEEPA_RATE_AUTHORITIES` category; `set_active` already worked. **Baseline = empty ops → `apply_operations` is a no-op there; only `scenario_ops.R` changed (validate/build path untouched) → baseline byte-identical, no 43-rev gate.** Unit: `test_scenario_ops` 61 (+11 IEEPA). **`set_floor` stays a deferred follow-up** (the only IEEPA verb not done — it's a separate verb, not in Plank 6 scope). Pass-1 now has only **Plank 5 (stacking generalization)** left.

**Plank 7 — drop the dual signature.** — ✅ **DONE (pulled FORWARD of 4b; parity GREEN 47/47
vs `tests/golden/9f9837d` — full 43-rev array `13836424` → gather `13836425` → compare
`13836687`/`13836688`, 0 violations / 0 errors).** `calculate_rates_for_revision()` now
REQUIRES `specs` and no longer accepts the bespoke `ieepa_rates`/`s232_rates`/`fentanyl_rates`
args (they were unconditionally overwritten from the spec). 3 commits: `74abc7d` (test-rewire:
Test-16 builds a per-half spec — the ONLY live specs-less caller); `cd94dd3` (signature-collapse:
drop the 3 args + delete every whole-authority specs-less fallback arm [301/201/122/232
re-extractions + scope hardcodes] + collapse the IEEPA/annex/301-tier guards, keeping the annex
`stop()` fail-closed guard + the §301 `from_list` sentinel ternary); `613a582` (gut the three
now-unreachable §232 helper blob fallbacks + strip dead params + delete `HEADING_RESOLVED_RATE_FIELD`
+ the deal-only `iso_to_census_vec` closure; net −62 lines). Byte-identical by construction
(production already passed specs at `00:138`/`09:1376`). The §232 residual blob (decision-8 gate
inputs + derivative blends) stays by design. NOTE: `test_rate_calculation.R` was NEVER a calc
caller (the earlier "rewire the parity-blind invariant test" cost was illusory — decision #10).

## Plank 4c — §232 ANNEX-REGIME RATE DE-BLOB — ✅ CLOSED (parity GREEN 47/47; commits 143a2b1 + 350c159)

> **DONE (2026-06-05).** Reframed with John (the annex is config-driven, not a blob) and built **SPEC-ONLY, no fallbacks**. The adapter classifies the product universe ONCE (`classify_s232_annex`,
> src/data_loaders.R) and writes an authority-level `section_232$annex = {tier, flat_rate, floor_rate, country_overrides}`; the calculator READS it — the inline classification, the config `case_when`
> literals, the UK case_when, and the Russia pmax loop are all DELETED (an annex-era revision with no spec `$annex` stops loudly). `country_overrides` carries the UK deal (mode 'replace') + country
> surcharges (mode 'max', e.g. Russia) — `mode` keeps Russia bit-exact without the "200% dominates" assumption. **STAYS calc-side** (genuine contextual/blend, decision 8): Taiwan civil-aircraft exemption,
> subdivision-r, zero-metal-content. Cleanup: deleted `tests/test_tpc_comparison.R` + `data/tpc/` (vestigial); rewired the annex-era specs-less callers in `run_tests_daily_series.R` to build+pass specs.
> See the two Progress-log entries + memory `theseus-4c-reframe`. The deferred-design notes below are SUPERSEDED by the actual build (single authority-level `annex` carrier, NOT per-metal by_product_tier).

> **Why this exists:** S3 (Plank 4a close-out) parked the §232 annex regime as calculator logic and the original S3
> note claimed it "needs a new `s232_annex` axis on `resolve_rate`." **That was an overstatement — corrected here.**
> The annex tier RATES and the UK annex deal ARE expressible in the EXISTING spec at the PRODUCT grain; no new
> resolver axis is needed. They were deferred for *relocation effort + entanglement*, not impossibility. This is a
> parity-SAFE de-blob (a relocation; changes no numbers), so — unlike the Pass-2 appendix items — it needs **no
> oracle**; the existing 43-rev numeric-tolerance parity harness validates it. It can be done as a late Pass-1-style
> plank whenever we pick it up.

**The insight (why it fits the spec):** each hts10 classifies into EXACTLY ONE annex tier, so `product(×country) → rate`
is single-valued. The existing layers + precedence (`overrides > by_product_tier > by_country > default`) carry it:
- **annex_1a / annex_1b / annex_2 flat tiers** → `by_product_tier` (product → 0.50 / 0.25 / 0). (Generic, all countries.)
- **UK annex deal** (`06:~2235-2246`) → `overrides` entries: UK × {annex_1a steel/alum products} → 0.25, UK ×
  {annex_1b steel/alum products} → 0.15. `overrides` outranks `by_product_tier`, so UK automatically wins over the
  generic tier — no special-casing, no annex axis. (My earlier "no spec layer can return 0.25-or-0.15-by-tier" was
  wrong: each PRODUCT is in one tier, so per-product it's a single rate.)
- **annex_3 floor** (`06:~2168`, `pmax(floor_rate − base, 0)` vs the ORIGINAL base) → the S2 `floors` layer (already
  built — `floor_static` semantics). 

**The actual work (why it's deferred, not done in S3):**
1. **Relocate the CLASSIFICATION into the adapter.** product→tier today is CSV longest-prefix-first match
   (`load_annex_products`, `resources/s232_annex_products.csv`) **plus** unmatched-product INFERENCE (primary chapters
   72/73/76/74 → annex_1a; unmatched derivatives → annex_1b) — `06:~2118-2175`, ~150 lines. The adapter must reproduce
   that EXACTLY at build time, then emit the per-product spec rates. This is the bulk of the work and the parity risk.
2. **Leave the NON-FLAT annex rules in the calc (decision 8):** country surcharges (`pmax` overlay, `06:~2248-2310`,
   e.g. Russia 200% aluminum), subdivision-r blend (`06:~2334-2416`), annex-III sunset (`06:~2312`). These are blends,
   not flat product→rate.
3. **Taiwan civil-aircraft exemption STAYS regardless** (`06:~3074-3096`) — it zeroes by metals-annex PROVENANCE
   (`!is.na(s232_annex)`) and NULLS the `s232_annex` column; that is genuinely not a `product×country→rate` (this is
   the one S3 verdict that was NOT an overstatement).
4. **Entanglement — move as a COHERENT UNIT.** The `s232_annex` tag also feeds NON-rate consumers (the Taiwan gate,
   zero-metal-content). So the relocation = (classify product→tier in the adapter → emit spec rates → still compute
   the `s232_annex` tag for the surviving non-rate gates). Don't relocate the rates piecemeal and orphan the tag.

**Gate:** standard 43-rev parity harness vs `tests/golden/9f9837d` (parity-safe by construction; a RED gate ⇒ the
relocated classification/inference drifted, not a schema gap). Slice like S2 if the first gate is red:
`by_product_tier` tiers → UK `overrides` → annex_3 `floors`. Adversarially re-derive a UK annex_1a + annex_1b product
and one annex_3 product vs the golden before gating.

**Dependency note:** this overlaps the annex tier with §232's existing `default`/`by_country` layers, so it's cleanest
AFTER Plank 4b (IEEPA) lands, or as a standalone — it does not block 4b.

## Pass-1.5 — product-exemption SETS into the spec — ✅ DONE / CLOSED — parity GREEN 46/46 (commit `55090cc`)

> **DONE (2026-06-06) — parity GREEN 46/46, 0 violations, 0 errors vs `tests/golden/70b6b97`** (build array
> `13878587` → gather `13878588` → parity array `13879290` → summary `13879291`; all 42 snapshots + the 4 daily
> aggregates within tolerance). Bit-exact relocation, as designed. Built **Route A (sets-in-spec)** per the recommendation below. The adapter
> bakes the four hand-curated exempt sets onto the program as a plain `$exempt_products` field (invisible to
> `validate_authority_spec`, like §232's residual `rate$resolved` blob — **no schema change**); the calc READS
> them at the existing load sites and keeps all masking. Three verbatim relocations
> (`.resolve_ieepa_exempt_products` / `.resolve_country_eo_exempt` / `.resolve_s122_exempt`, mirroring
> `.resolve_ieepa_*`); floor reuses `load_revision_floor_exemptions()`. Baked onto:
> `ieepa_reciprocal$programs[[1]]$exempt_products = {universal, country_eo, floor}` and
> `section_122$programs[[1]]$exempt_products = {hts8}`. The fentanyl Ch98 subset rides along (calc derives
> `universal[ch==98]`). Bit-exact by construction. Unit-green: `tests/test_exempt_sets_in_spec.R` 20/20
> (adapter helpers == verbatim pre-relocation calc code across the live date windows + end-to-end baking +
> `validate_spec_set` unaffected); `test_ieepa_deblob` 32, `test_authority_adapter` 44 (both gained a
> `load_revision_floor_exemptions` stub now that `build_authority_specs` does CSV I/O). **Gate: 43-rev array
> `13878587` → gather `13878588` → parity vs `tests/golden/70b6b97` (pending).** See Progress log.

> Candidate "Pass-1.5" plank flagged by John (2026-06-06), after Plank 4b closed. Spec'd here for when we pick it up.

**The gap.** The rate de-blob made the spec the source of truth for *what rate applies to whom*, but the **product-exemption sets** are still loaded directly by the calculator from hand-curated resource CSVs — they never enter the spec. The convention is uniform across authorities (**rate → spec; product-exemption set → calc-loaded CSV**), so this is a house pattern, not an IEEPA quirk. The calc-loaded sets:
- `resources/ieepa_exempt_products.csv` (~4,298 hts10 — universal Annex II; `06:~962`)
- `resources/country_eo_exempt_products.csv` (~970, **date-gated** rows; `06:~978`)
- `resources/floor_exempt_products.csv` (~3,824, keyed by **(hts8, country_group)**; loaded via `load_revision_floor_exemptions`, `06:~1007`)
- `resources/s122_exempt_products.csv` (§122's analogous list; `06:~2411`) — **same pattern**, so fold it in here.
- the Ch98 fentanyl subset is *derived* from `ieepa_exempt_products` (`substr==98`), so it rides along.

**Provenance (why they're treated differently from rates).** Rates are PARSED from the HTS JSON Chapter-99 headings (`extract_ieepa_rates`/`extract_section122_rates`). These exempt lists are **NOT in that JSON** — they are hand-transcribed from the EO annexes / US Notes into resource CSVs; `expand_ieepa_exempt.R` only *expands* the hand-curated HTS8 seeds to HTS10 (+ adds whole chapters 98/97/49 by rule). So they're a separate, hand-curated input stream that no parser touches — which is why the adapter (built from parser objects + config) never sees them today.

**Feasibility = yes, not a technical blocker.** They are just sets of hts10 codes. The adapter is per-revision and already loads config + resource files, so it can load these CSVs and bake them onto the program (e.g. `programs[[1]]$exempt_products`, or a `rate$product_exempt` layer). The **masking stays calc-side** (`hts10 %in% set` needs the product grid); only the SET — the source of truth — moves into the spec. Precedented: §232 already relocated its **country** exemptions (→ `by_country = 0`) and its annex **classification** (→ `section_232$annex`) the same way.

**Wrinkles the adapter must handle (all already-solved patterns):**
- `country_eo_exempt` is **date-gated** → the per-revision adapter pre-resolves the *active* (ch99, hts8) set at the revision date and bakes that (mirrors the §232 config-exemption date-gate baking).
- `floor_exempt` is **(hts8, country_group)**-keyed, not a flat set → bake the keyed structure (a small structured field), not a vector.
- These are LARGE (~9k codes total) and the spec serializes per-revision to RDS → accept the size bump, or keep them as a per-spec reference handle.

**Stays calc-side regardless (NOT this plank):** the §232 **Taiwan civil-aircraft** exemption — it gates on metals-annex *provenance* (`!is.na(s232_annex)`) and *nulls* a calc column, which a spec field can't express (the one S3 verdict that was not an overstatement). The IEEPA/s122 exempts have **none** of that entanglement (plain "zero the rate for these products"), so they relocate cleanly.

**Honest value caveat.** Lower-value than the rate de-blob: the rates were hidden in opaque blobs (the whole point of de-blobbing), whereas these exemptions are already clean, inspectable, version-controlled CSVs — a defensible source of truth as-is. This plank is about *uniformity* ("the spec holds everything"), not rescuing hidden data.

**Two ways to model it — and why §232 and IEEPA split.** The schema already has the right field for this: `product_scope` (`include: 'all' | chapters | prefixes | list` + `exclude`), with a reusable resolver at `new_coverage.R:30` (`resolve_product_scope`). But the blanket calc paths (IEEPA, s122) **do not read `product_scope` today** — they apply to ALL products and mask inline (same as they ignore `country_scope`), so EITHER route below also needs a small wiring step (teach the calc to resolve + apply `product_scope`).
- **Route A — sets-in-spec (the lighter relocation; what the rest of this section assumes).** The spec carries the exempt SETS as data; the calc keeps the conditional masking. Parity-safe relocation, small blast radius. Recommended default.
- **Route B — express exemptions AS scope (the fully-declarative ideal).** `product_scope = include:'all'` minus an `exclude` set (IEEPA) or a positive product listing (§232). More elegant (the engine just resolves scope; no exempt-masking code), but it is a RESTRUCTURING, not a relocation — and it does **not** cleanly fit IEEPA:
  - **§232 — close to a drop-in.** §232's scope really is a positive product listing (metal chapters + derivative lists + annex tiers), much of which is already spec-side. Caveat: two genuine NON-scope residuals can't be expressed as in/out and stay calc-side regardless — derivative **metal-content scaling** (a *fraction*, not membership) and the **Taiwan** exemption (gates on annex provenance + *nulls* a column).
  - **IEEPA — a single `all − exempt` is too coarse, for two reasons.** (1) The universal Annex II exempt is **per-rate-COMPONENT, not absolute**: country-EO surcharges (Brazil `9903.01.77`, etc.) BYPASS it and use their own list (`06:~1220` `case_when`: `if_else(exempt_active, 0, rate − eo_rate) + if_else(is_country_eo_exempt, 0, eo_rate)`), so a universally-exempt product can STILL owe the EO surcharge — yanking it out of `product_scope` wholesale would wrongly kill that. (2) `floor_exempt` is product × **country-GROUP** (keyed `hts8|country_group` — exempt for EU, not China), which a product-only `product_scope` can't express. (Plus the `ieepa_exempt_scope` toggle changes WHICH layers the exempt hits.) To model IEEPA faithfully as scope you'd have to **decompose the one reciprocal program into several** (baseline / phase / per-country-EO), each with its own `product_scope` + `country_scope` carrying its distinct exempt set — the fully-declarative end state, but a real re-representation of IEEPA, and IEEPA is repealed (value = uniformity, not scenarios). So: Route B for §232 if/when convenient; Route A (sets-in-spec) for IEEPA unless we deliberately take on the program-decomposition.

**Gate.** Parity-SAFE by construction (a relocation, no number change → no oracle). Standard 43-rev array vs `tests/golden/9f9837d`; a RED gate ⇒ a relocation detail drifted (date-gate boundary, country-group key, Ch98-subset derivation), not a schema gap. Slice by file (ieepa universal → country_eo → floor → s122) if the first gate is red.

## Verification

> **GOLDEN INCREMENTED 2026-06-06 → `tests/golden/70b6b97`.** After Pass-1 closed, the
> six "extreme-eta" policy fixes + the revision re-dating from `master` were ported in and
> the golden was re-frozen (these are behavior-changing — they move numbers on purpose).
> Pass-1's planks were all gated against `9f9837d` (the references below are historically
> correct); **future parity runs should use `tests/golden/70b6b97`.** Daily-rate impact +
> the full port log: `docs/master_fix_integration.md`. `9f9837d` is retained for provenance.

- **Baseline golden:** `tests/golden/9f9837d` (the native-format twin of the published
  `2026-06-04_2` vintage; same commit, `policy_params_md5` matches the manifest). Captured
  via `scripts/capture_parity_golden.R`.
- **Per plank:** numeric-tolerance parity gate (panel + daily) via the existing harness,
  ε per column class (decision 3).

  **USE THE PARALLEL ARRAY BUILD — never the serial `00_build_timeseries.R --full`.**
  The monolithic builder's `--workers` flag is a no-op (serial: ~1h45m for 43 revisions;
  Plank 1 burned that once). The array path builds one Slurm task per revision concurrently
  (~10–15 min) and is what built the golden:
    1. `bash scripts/submit_build_array.sh` (with `GATHER_ARGS="--unweighted"` to skip the
       un-gated weighted ETR) — generates the revlist, submits one array task per revision,
       and chains the gather (assemble → daily) via an `afterok` dependency.
    2. then `Rscript scripts/run_parity_check.R --golden tests/golden/9f9837d --artifacts
       snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category`.
  - The array path rebuilds **every** revision fresh, so it has no "incremental no-op" trap.
    (The serial builder WITHOUT `--full` silently reuses on-disk snapshots → a false-green
    gate; Plank 1's first run hit exactly this. If ever using the serial path, `--full` AND
    pre-delete `data/timeseries/snapshot_*.rds`.)
  - **Skip the monolithic `timeseries` artifact** in the parity check: the 1.38 GB
    `rate_timeseries.rds` ×2 OOMs at 192 G. The 43 per-snapshot comparisons cover the same
    data one file at a time (memory-safe), with no loss of coverage.
  - The golden is frozen in `tests/golden/`, so the array build overwriting
    `data/timeseries/` is safe.
- **Plank 0:** unit tests on `resolve_rate`/`apply_rate_semantics`/`validate_rate` (no recompute).
- **Planks 1/6:** also add scenario unit tests (rescope 301; rescope/rebump IEEPA).
- A plank is "done" only when parity is green within tolerance AND its bespoke branch(es)
  are deleted (deleting only the branch while leaving scope hardcoded is a silent miss).

  > **Parity ≠ correctness.** The gate compares candidate vs golden, so it only catches
  > *changes* — it is **blind to bugs already baked into the golden** (candidate and golden
  > agree → green). Absolute-invariant unit tests (e.g. `tests/test_rate_calculation.R`) are
  > what catch latent baseline bugs; keep running them alongside the gate. (This is the same
  > reason Pass 2 — behaviour changes — needs an external oracle, not parity.) Live example:
  > the Russia §232 aluminium-surcharge leak (below) is present in the golden, so parity is
  > green on those snapshots while `test_rate_calculation` fails its Russia invariants.

## Hygiene (fold in opportunistically)

- Fix the list-column bug in `scripts/diagnose_parse_loss.R` (the bogus ~70% all-dangling
  metric; `n_dangling_codes=0` is the real signal) before anyone reruns it.

## Known pre-existing bugs (NOT introduced by this refactor; flagged for John)

- **Russia §232 aluminium-surcharge leak.** `tests/test_rate_calculation.R` fails 3 absolute
  invariants (lines ~856/872/908) on `snapshot_2026_rev_5.rds`: the 200% Russia surcharge
  (scoped to *aluminium*) appears to leak onto (a) Russia *steel* (HS 72/73) and (b) Annex-II
  non-semiconductor products that should be §232-exempt (Note 39a invariant). Present in the
  current **golden** data, so the parity gate is green on it — only the invariant tests catch
  it. Behaviour-changing to fix → its own task (likely a Pass-2 / surcharge-scoping item),
  out of scope for the Pass-1 planks.
- Non-fatal quality-report `$`-on-atomic error during the build (build still exits 0); not
  from the spec work (`quality_report.R` doesn't touch `by_product_tier`).

## Appendix — Pass 2 (NOT in scope; specified for the future)

Pass 2 = the **behavior-changing** fixes. They change numbers on purpose, so parity
cannot validate them — each needs an **external oracle**, which does not exist today.

- **P2-0 — build the oracle (gates all of P2).** Restore the TPC benchmark
  (`data/tpc/tariff_by_flow_day.csv`, possibly recoverable from ji252's tree) or curate a
  hand-checked ground-truth set for the worst complex/edge cases. Specify ε per column class.
- **P2-1 — unified timeline splitter. CODE LANDED on `theseus` (golden re-freeze pending).**
  Implemented via **minting**, not the planned `09` splitter-swap: `discover_boundaries()`
  (`src/timeline.R`) finds every boundary strictly interior to a real interval that the calc
  re-resolves on an as-of recompute, and `build_boundary_mints()` (`src/00_build_timeseries.R`)
  mints one baseline-eligible `bnd_<date>` snapshot per boundary (owner archive stamped at D,
  empty ops) → `assemble_timeseries` derives the interval. The state-change is the recompute
  itself (no new calc code). Verified mintable set on the policy grid: **2025-03-12** (§232
  metal country-exemption expiry, in-window — NOT a Ch99 offset as the plan assumed),
  **2026-02-20** (IEEPA invalidation; resolves the 02-20-vs-02-24 question → 02-20 under
  `use_policy_dates`), **2026-11-10** (§301 cranes/chassis turn-on — newly discovered; closes
  the "never turns on" hole). **Mutual-exclusion rule:** S122/Swiss expiries stay on downstream
  `apply_expiry_zeroing` (mint≡zeroing for S122 but ≠ for Swiss — the surcharge revert), so the
  `09:~326` splitter is left unchanged and `discover_boundaries` subtracts `expiry_boundaries()`.
  Behavior-changing → validated by statute invariants (`tests/test_timeline_invariants.R`) +
  golden re-freeze, not parity-vs-old-golden. Full note: `docs/timeline_split_integration.md`.
- **P2-2 — parser non-ad-valorem (~4% of import value).** Represent compound/specific duties
  the parser currently drops to `NA`/`has_complex_rate`. Oracle-gated.
- **P2-3 — unify scenario surfaces.** Statutory deltas (`operations`) and adjustment deltas
  (`pp_override` / rebuild-alts) are two separate code paths; unify to `policy × adjustment`.
- **P2-4 — per-revision spec persistence.** Save each revision's resolved spec +
  adjustment_params so a `base: <date>` pin reproduces "what we knew then".
- **P2-5 — fold parser→spec, delete Layer B.** Parser emits specs directly. Low value, large
  blast radius; do last.

## Supersedes

This plan consolidates and supersedes the earlier scattered phase docs for the
calculator-refactor strand (since removed).

## Progress log

- **2026-06-06 — Pass-2 / P2-1 (unified timeline splitter) — DONE + GOLDEN RE-FROZEN.** Build (array `13905511` → gather `13905512`, policy grid) minted the 3 `bnd_` snapshots; impact vs prior golden `70b6b97` is surgical — **6 daily rows move, all inside the boundary windows, 0 outside** (regression guard green): 2025-03-12/13 +0.22pp unweighted / +0.54pp `etr_232` (§232 metal-exemption expiry), 2026-02-20→23 IEEPA reciprocal+fentanyl → 0 (−9.2pp unweighted / weighted_etr 13.1%→7.5%, the 4-day pre-S122 window). `test_timeline_invariants` **16/16 green** vs the real build. Commits `1f07a3e` (mechanism) + `6ec81b9` (validation + §301 invariant + weighted-chart/impact tooling) + `f09d279` (first re-freeze `tests/golden/6ec81b9`). **§301 cranes/chassis PRICED (follow-up, after John said "do that"):** the scan surfaced that the 2026-11-10 codes `9903.91.12` (chassis, note 31(k)(i)) / `9903.91.14` (cranes, note 31(l)) carry +100% in the Ch99 text but were absent from `section_301_rates` → mint was daily-inert. Added `9903.91.12/.14 → 1.00` to `section_301_rates` + the covered hts8 (`87163900/87169030/87169050 → .12`, `84261900 → .14`) to `s301_product_lists.csv`. Only `bnd_2026-11-10` changes (codes gated to 11-10, masked in every real rev — one-revision re-mint, job `13911763`): China cranes `8426.19` + chassis `8716.39/.90` `rate_301` rises **0.25 → 1.00** via MAX. Final impact vs `70b6b97`: **58 daily rows move, ALL in-window, 0 outside** (52 = the `[11-10,horizon]` priced interval; small — `etr_301` +0.016pp). `test_timeline_invariants` **17/17**. Judgment calls (documented): omitted `.13/.15/.16` (= +0% complements/exemptions, MAX-mooted), hts8 over-application of `.12` to all of `87163900`. **Golden RE-FROZEN again at `tests/golden/52dab78`** (commit `52dab78`; `policy_params_md5 4afe9508…`; supersedes 6ec81b9; `70b6b97` retained). Note: `docs/timeline_split_integration.md`.
- **2026-06-06 — Pass-2 / P2-1 (unified timeline splitter) — CODE + UNIT TESTS LANDED on `theseus`, golden re-freeze PENDING.** Implemented as **boundary minting** rather than the plan's literal `09`-splitter swap (see the corrected P2-1 appendix). `discover_boundaries()` (`src/timeline.R`) unions a Ch99 `effective_date_offset` scan (interior-to-own-rev) + IEEPA invalidation (`collect_schedule_boundaries` − `expiry_boundaries`) + §232 country-exemption expiries + curated `boundary_overrides`; `build_boundary_mints()` (`src/00_build_timeseries.R`, sibling of `build_scheduled_activations`) recomputes the owner archive stamped at each boundary into a baseline-eligible `bnd_<date>` snapshot (empty ops), wired before `build_scheduled_activations` in both `build_full_timeseries` + `scripts/build_gather.R`. **Discovery reconciled two plan errors:** 2025-03-12 is the §232 country-exemption expiry (NOT a Ch99 derivative offset — the derivatives are ungated in rev_4), and **2026-11-10** (§301 9903.91.12–.16 cranes/chassis, China, "on or after Nov 10, 2026") is a genuinely-NEW discovered turn-on the current pipeline masks forever. Exactly **3 mints** on the live grid: 2025-03-12 (rev_4, in-window), 2026-02-20 (2026_rev_3), 2026-11-10 (2026_rev_9). **Mutual-exclusion (R4/R8):** S122/Swiss expiries stay on downstream zeroing (mint≡zeroing for S122, ≠ for Swiss's surcharge-revert), so `discover_boundaries` subtracts `expiry_boundaries()` and `09:~326` is untouched. Unit-green: `test_boundary_discovery` 26, `test_mint_equals_zeroing` 9, `test_timeline_realdata` 4 (kept live≡legacy parity), `test_timeline` 10 + `test_timeline_swap` 7 (no regression); `test_timeline_invariants` skips until the build mints the `bnd_` snapshots. `boundary_overrides: []` added to `policy_params.yaml` (loaded as `pp$BOUNDARY_OVERRIDES`). **Next:** array build → `test_timeline_invariants` green → `scripts/report_timeline_split_impact.R` → re-capture golden (manifest must expect real + the 3 `bnd_`; R5). Note: `docs/timeline_split_integration.md`.
- **2026-06-06 — Pass-1.5 (product-exemption SETS -> spec) DONE/CLOSED — parity GREEN 46/46** (build array `13878587` → gather `13878588` → parity array `13879290` → summary `13879291`: 46/46 pass, 0 violations, 0 errors vs `tests/golden/70b6b97`; all 42 snapshots + 4 daily aggregates within tolerance). Committed `55090cc`. John chose this (Pass-1 done; picked the parity-safe uniformity plank over the Russia-§232-leak / oracle-recovery options). Built Route A (sets-in-spec, calc keeps masking) — the lowest-blast-radius option, NO schema/validator change. The adapter (`build_authority_specs`) bakes four date-resolved exempt sets onto a plain program-level `$exempt_products` field (invisible to `validate_authority_spec`, exactly like §232's `rate$resolved` blob): `ieepa_reciprocal` gets `{universal, country_eo, floor}`, `section_122` gets `{hts8}`. Three new verbatim relocations of the calc's old inline load+date-gate (`.resolve_ieepa_exempt_products` / `.resolve_country_eo_exempt` / `.resolve_s122_exempt`, fully qualified + base-pipe so they work in the attach-minimal isolated harnesses, mirroring `.resolve_ieepa_*`); floor = the existing `load_revision_floor_exemptions(revision_id)` (committed per-revision files → bit-identical). Baking is UNCONDITIONAL (universal also feeds fentanyl Ch98, on its own gate). The calc READS the sets at the existing load sites (06: −45 net lines) and all masking math is untouched; the fentanyl Ch98 subset rides along (`universal[ch==98]`). Bit-exact by construction. **Ripple handled:** `build_authority_specs` now does CSV I/O, so the two isolated adapter harnesses (`test_ieepa_deblob`, `test_authority_adapter`) gained a `load_revision_floor_exemptions` stub. Unit-green: new `tests/test_exempt_sets_in_spec.R` 20/20 (adapter == verbatim pre-relocation oracle across live date windows; end-to-end baking; `validate_spec_set` unaffected), ieepa_deblob 32, adapter 44, spec 19, resolve_rate 70, scenario_ops 71. **Gate:** array `13878587` (42 tasks) → gather `13878588` (afterok) → `GOLDEN=tests/golden/70b6b97 sbatch scripts/submit_plank3_parity.sh` (pending). Parity-safe relocation → GREEN expected by construction; RED ⇒ a date-gate boundary / country-group key / Ch98-derivation drifted. NOTE: §232 Taiwan civil-aircraft exemption deliberately STAYS calc-side (gates on annex provenance + nulls a column — not a product→set). IEEPA exempts modeled as Route A (sets-in-spec) not Route B (scope) — Route B doesn't cleanly fit IEEPA (per-rate-component exempts + country-GROUP floor keys); see the Pass-1.5 section.
- **2026-06-06 — Plank 5 (stacking generalization) DONE/CLOSED → PASS-1 COMPLETE — parity GREEN 47/47** (array `13867594` → gather `13867595` → parity array `13867821` → summary `13867822`: 47 passed / 0 failed, ALL ARTIFACTS WITHIN TOLERANCE vs `tests/golden/9f9837d`). John handed it off autonomously ("go to the stacking phase… figure it out"). Mapped + adversarially verified the design first (workflow `wf_2322681a-b45`, 10 agents), which reframed it: the stacking MATH was already generic (Phase 3a), so the lift was wiring the policy to come FROM the spec, plus the metal-map dedup and resolved_programs disposition. Slices (all unit-green): **5a** metal-map dedup (`9c54673`, `test_metal_chapters` 7/7) — the map was already config-backed via `cc$STEEL/ALUM_CHAPTERS`; added copper + repointed the live adapter literals. **5b** `stacking_policy_from_specs()` routed through `06:2820` (`d63d3bf`, `test_policy_from_specs` 13/13) — skeleton-override design, byte-identical to `default_stacking_policy()` by the pinned `identical()` invariant; THE core + the only build-path risk. **5c** resolved_programs **UNIFY-not-delete** (`0181e8c`, `test_resolved_programs` 12/12) — DEVIATES from decision 9's literal "delete" (its orphan-301_cs rationale is stale; the file is the Wire-2 substrate); derived `precedence` from policy order, threaded the spec policy into the flag-off branch, and **fixed a latent pre-existing crash** (missing `rate_301_cs` guard in `build_resolved_programs` — the test was silently failing on HEAD). **5d** `set_stacking` verb (`428ef3c`, `test_scenario_ops` 71/71) — closes the "no set_stacking op" gap; parity-trivial; honest 09-specs-less boundary documented. Unit suites all green (adapter 44, spec 19, resolve_rate 70, stacking 13, classify_annex 10). **With the gate GREEN, Pass-1 is COMPLETE.** Open for John: the 5c UNIFY-vs-DELETE call (revertible) and whether to thread spec/policy into 09 (Pass-2). 5a touched `policy_params.yaml`, but the ARRAY parity path does no config-md5 check (only the serial `run_parity_check.R` does), so no `--no-config-check` needed.
- **2026-06-06 — Plank 6 DONE (IEEPA scenario verbs) — commit `7318eff`, unit-green, parity-trivial (no rebuild).** Enabled by 4b's structured IEEPA rate: `scenario_ops.R` now supports `set_rate`/`set_country_scope`/`disable` for `ieepa_reciprocal`+`ieepa_fentanyl` (previously errored). `set_rate` is per-country (`op$country` → `by_country[c]`; reciprocal writes a clean flat surcharge, dropping the EO two-term so the companion maps stay parallel); `set_country_scope` honors `exclude` (drop → 0; reciprocal also extends `default_unlisted_exclude`) and `include={set}` (restrict listed + reciprocal baseline off); `disable` clears every rate layer (calc `has_active_ieepa`/`has_fentanyl` gate → OFF). New `IEEPA_RATE_AUTHORITIES` category; `set_active` already worked. **No 43-rev gate (Plank 1/2 precedent):** baseline = empty ops → `apply_operations` no-op; only `scenario_ops.R` touched (validate_rate + build path unchanged since S1/S2) → baseline provably byte-identical. Unit: `test_scenario_ops` 61/61 (+11 IEEPA: disable both programs, per-country set_rate incl. new-country growth + clean-surcharge semantics, exclude/include scope, fentanyl carve-out drop, copy-on-modify isolation, missing-`country` fail-loud). `set_floor` is the one deferred IEEPA verb (separate, out of Plank-6 scope). **Pass-1 remaining: ONLY Plank 5 (stacking generalization) — left for John to greenlight (bigger non-IEEPA refactor, needs a full parity gate).** This was the autonomous overnight stopping point John set ("do 6, finish at 6").
- **2026-06-05 — PLANK 4b CLOSED — IEEPA fully spec-driven (S1+S2 parity GREEN 47/47, S3 cleanup unit-green).** The last blob authority is de-blobbed: reciprocal (S1, `a6700e7`) + fentanyl (S2, `d3cc1ee`) rates are structured compositional layers the calc reads; **S3** (`b6e1ce9`) removed the now-dead `ieepa_rates_from_specs`/`fentanyl_rates_from_specs` accessors (zero callers — parity-trivial, no rebuild, Plank-2 reasoning). Only §232 still carries a residual decision-8 blob. The genuinely procedural bits stay as calc steps reading spec data (3 exempt maskings, IEEPA-only grid expansion, post-MFN floor recompute, fentanyl carve-out hts8 join). **Remaining Pass-1: Plank 6 (IEEPA scenario verbs — now enabled by the structured rate), Plank 5 (stacking generalization).**
- **2026-06-05 — Plank 4b / S2 (IEEPA fentanyl de-blob) — committed `d3cc1ee`, parity GREEN 47/47** (array `13845197` → gather `13845198` → parity `13846019`/`13846020`; 47/47 pass, 0 violations, 0 errors vs `tests/golden/9f9837d`). De-blobbed the fentanyl rate, **minimal/lowest-risk slice**: only the *rate* data leaves the blob; the carve-out PRODUCT lists (hts8 prefixes, `resources/fentanyl_carveout_products.csv`) stay reference data loaded calc-side (consistent with the IEEPA exempt CSVs kept calc-side in S1). Adapter `.resolve_ieepa_fentanyl` does the general-rate **max-per-census collapse** (China 9903.01.20 +10% / .24 +20% → max) → `rate$by_country`, and emits the per-ch99×census carve-out rates → `rate$carveouts` {ch99_code, census_code, rate}. **No `rate$resolved` blob.** The calc reconstructs `general_fent` / `carveout_fent` from the spec layers and the CSV-join + `coalesce` + `add_blanket_pairs` + Ch98 exemption are byte-identical; invalidation now gates fentanyl via `ieepa_invalidated` (no more `fentanyl_rates <- NULL`). `validate_rate` checks the carveouts shape; `resolve_rate` UNCHANGED. **Unit gate:** `tests/test_ieepa_deblob.R` 32/32 (added 9 fentanyl checks: adapter==old-calc oracle for max-per-census + carveout extraction, hand-checks CN 0.20/CA 0.35/MX 0.25, end-to-end no-blob), adapter 44, spec 19, resolve_rate 70, scenario_ops 50. **After S2 green:** S3 = remove the now-dead `ieepa_rates_from_specs`/`fentanyl_rates_from_specs` accessors (both unreferenced by the build path after S1/S2 — parity-trivial dead-code removal, no rebuild needed).
- **2026-06-05 — Plank 4b / S1 (IEEPA reciprocal de-blob) — committed `a6700e7`, parity GREEN 47/47** (array `13843583` → gather `13843584` → parity orchestrator `13844250` → array `13844275` → summary `13844276`; 47/47 pass, 0 violations, 0 errors vs `tests/golden/9f9837d`). De-blobbed the IEEPA reciprocal rate. **Design (deviates from the plan's literal "phase structure as spec data + generic collapse primitive" — see note):** the reciprocal phase-collapse (`active_ieepa` → `country_ieepa` group_by/summarise) AND the surcharge→floor override (FLOOR_COUNTRIES, Swiss/LI framework-window gated) are **pure deterministic functions of the parsed tibble + floor config + revision date** — all available in the adapter (which already does this for §232 blanket). So I **relocated both VERBATIM into the adapter** (`.resolve_ieepa_reciprocal`, src/authority_adapter.R), which emits RESOLVED per-country structured layers; the calc READS them. This is **bit-exact by construction** (same code, same input) and yields cleaner resolved layers than carrying raw phase rows + a calc-side collapse. `ieepa_reciprocal$programs[[1]]$rate` is now real structured data, **no `rate$resolved` blob**: `by_country` (post-override rate) + `by_country_type` (per-country surcharge|floor|passthrough — schema promotion, decision 2) + `by_country_eo_rate`/`by_country_eo_ch99` (country-EO two-term components, decision 1) + `default_unlisted_rate` (universal baseline, decision 5) + `default_unlisted_exclude` = c(CA,MX) (decision 3). The calc rebuilds `country_ieepa` from these and **keeps the genuinely procedural bits as calc steps** (they need base_rate / the product grid): the 3 exempt maskings (universal Annex II, country-EO, floor-country), the IEEPA-only grid expansion, and the step-6d post-MFN floor recompute (its `ieepa_type` now threaded from `by_country_type`). `validate_rate` accepts the 4 new fields (+ `carveouts` for S2); **`resolve_rate` UNCHANGED** (calc-read, like the §232 annex). **Unit gate:** `tests/test_ieepa_deblob.R` 23/23 — runs the OLD calc phase-collapse+override as an ORACLE and asserts the adapter reproduces it bit-for-bit (all collapse + override branches: Brazil 10%+40%=50%, India, Tunisia within-phase-max, France floor-override, Germany below-floor-no-override, Switzerland in/out-of-window, phase2-supersedes-phase1, passthrough, no-EO) + hand-checked values + end-to-end no-blob. adapter 42, spec 19, resolve_rate 70, scenario_ops 50 all green. **Remaining 4b:** S2 (fentanyl: `by_country` max-per-census + `carveouts` field), S3 (cleanup: drop `ieepa_rates_from_specs`/reciprocal `$resolved` is already gone; drop fentanyl blob accessor after S2). Then Plank 5 (stacking), 6 (IEEPA verbs).
- **2026-06-05 — Plank 7 DONE (pulled FORWARD of 4b) — parity GREEN 47/47.** Retired the
  specs-less dual signature: `calculate_rates_for_revision()` now requires `specs`. 3 commits
  (`74abc7d` test-rewire → `cd94dd3` signature-collapse → `613a582` §232-helper-cleanup; net
  −62 lines in `06`). Scoped first by the `plank7-4b-lockdown` fan-out workflow (5 mappers → 3
  adversarial verifiers → synth), which CORRECTED the plan: `test_rate_calculation.R` is NOT a
  calc caller (only Test-16 in `run_tests_daily_series.R` was specs-less), so the feared "rewire
  the parity-blind invariant test without silencing its Russia-leak invariants" cost did not
  exist (decision #10 fixed). Deleted every whole-authority specs-less fallback (301/201/122/232
  re-extractions + scope hardcodes) + the three §232 helpers' blob fallbacks + their unused
  params/maps. Units green modulo pre-existing fails (daily-series 78/1 pharma-gate; adapter
  41/41; scenario_ops 50/50; spec 19/19; rate_calculation 86/3 Russia-leak). Gate: array
  `13836424` (43/43 COMPLETED) → gather `13836425` (COMPLETED) → parity array `13836687` +
  summary `13836688` = 47/47 pass, 0 violations, 0 errors vs `tests/golden/9f9837d`. Byte-identical
  by construction (production already passed specs). **Remaining Pass-1: 4b (IEEPA — the last
  blob), 5 (stacking), 6 (IEEPA verbs).** 4b deep-design pass pending; 4 open decisions surfaced
  for John — only the live one is per-country `rate_type` in the schema vs calc-derived (the §232
  annex tag-in-spec / math-in-calc pattern applies); the other 3 have low-risk defaults (country-EO
  blend stays calc-side; CA/MX baseline exclusion reuses `country_scope`; floor-exempt groups stay
  calc-side).
- **2026-06-05 — Plank 4c S2b+S2c DONE → PLANK 4c CLOSED (parity GREEN 47/47; commit `350c159`).** Relocated the
  last two §232 annex calc steps — the UK annex deal and country surcharges (Russia) — into the spec, spec-only/no
  fallback. The adapter emits `section_232$annex$country_overrides`: an ordered list of per-(country) per-product rate
  maps, each tagged `mode`. UK deal = `mode='replace'` (tier 1a/1b on chapters 72/73/76 → uk_rate 0.25/0.15); country
  surcharges = `mode='max'` (Russia aluminum 2.0 across annex 1a/1b/3, built from the same primary-chapter +
  type-tagged-derivative-prefix set the calc used, scoped to the surcharge's annexes via the tier map). The calc
  replaced the UK `case_when` + the Russia `pmax` loop with one read-loop over `country_overrides` (`replace`=flat set,
  `max`=pmax) — carrying `mode` keeps Russia **bit-exact without the "200% dominates" assumption**. Calc is now clean of
  `uk_code`/`country_surcharges`/`type_hts10`. **§232 annex regime is fully spec-driven** (tiers, flat rates, annex-3
  floor, UK deal, surcharges all read off `section_232$annex`); only Taiwan exemption + subdivision-r + zero-metal-content
  stay calc-side (genuine contextual/blend, decision 8). Gate: array `13832580` → gather `13832581` → parity
  `13833075/6` = 47/47, 0 violations. Unit: daily-series suite green (UK + Russia tests via the spec path) except the
  pre-existing pharmaceuticals-gate failure. Next theseus Pass-1: 4b (IEEPA, last real blob), 5 (stacking), 6 (IEEPA
  verbs), 7 (drop the dual signature — elevated by the no-fallbacks directive).
- **2026-06-05 — Plank 4c S1+S2a DONE (parity GREEN 47/47; commit `143a2b1`).** §232 annex regime de-blobbed to the
  spec, **SPEC-ONLY (John: "fuck fallbacks, fuck vestigial code")**. Reframed first: the annex is config-driven (not a
  blob), and the classification produces the `s232_annex` tag (read + mutated downstream), so John's instinct — the
  parser writes the facts, the calc reads — is right and the tag is a *symptom* of the classification being trapped in
  the calc. Built: **(S1)** `classify_s232_annex()` extracted to `src/data_loaders.R` (single source of truth; arm-order
  `7616109030`→1a preserved; 10 unit checks). **(S2a)** adapter `build_authority_specs()` classifies the product
  universe ONCE and writes an authority-level `section_232$annex = {tier, flat_rate (1a/1b/2→0.50/0.25/0), floor_rate}`;
  the calc READS tag+flat_rate off the spec and the inline classification + config `case_when` literals are DELETED
  (override = heading-wins → spec flat_rate → annex_3 floor vs base). No fallback: an annex-era revision with no spec
  `$annex` `stop()`s. Single authority-level carrier (rate is metal-agnostic) — sidesteps per-metal-routing completeness
  risk; heading carve-out handled by the existing heading-first arm; has_232 untouched (only the annex OVERLAY added,
  rate$default unchanged). **Cleanup:** deleted `tests/test_tpc_comparison.R` + `data/tpc/` (vestigial, benchmark gone);
  rewired the 5 annex-era specs-less calls in `run_tests_daily_series.R` to build+pass real specs (fail-closed test now
  exercises the adapter guard). Gates: classify 10/10; daily-series suite green except 1 PRE-EXISTING fail
  (pharmaceuticals heading gate, S1b artifact — not 4c); inline smoke green; **43-rev array `13831052` → gather
  `13831053` → parity `13831695/6` = 47/47, 0 violations vs `tests/golden/9f9837d`**. UK deal (S2b) + Russia surcharge
  (S2c) stay calc-side for now; Taiwan exemption + subdiv-r/zmc stay (contextual/blend, decision 8). The broader
  dual-signature removal (pre-annex specs-less callers + 301/122/IEEPA config fallbacks) is the natural Plank-7 follow-on.
- **2026-06-05 — Plank 4a S3 DONE → PLANK 4a CLOSED.** A focused lock-in workflow (`wf_0ccdd059-752`, 3 analyses +
  adversarial decision) proved S3 has no parity-safe de-blobbing left — it's a close-out, not a de-blob. Verdicts
  (all stress-tested): the **UK annex deal** and **Taiwan civil-aircraft exemption** MUST STAY — both are
  annex-tier-context logic (`s232_annex` tier / metals-annex provenance) that `resolve_rate` deliberately doesn't
  model in Pass 1, and their values are already config-driven (not blob); the **residual blob** is at its
  decision-8 floor (8 gate/derivative fields stay; `auto_exempt` is a verified no-op). S3's only code change =
  removing the dead `auto_exempt` calc read (`auto_rate` never set `rate_232`; the `auto_rate>0` filter term was
  fully subsumed by the heading-country union). Modeling the §232 annex regime in the spec (a new `s232_annex` axis
  on the resolver) is explicitly DEFERRED to Pass 2. With S3, §232 is a complete 8-program spec — clean statutory
  layers de-blobbed, decision-8 blends/gates legitimately residual. Gate: full 43-rev array (close-out gate).
- **2026-06-05 — Plank 4a S2 DONE — both commits parity GREEN 47/47.**
  Per John: develop direct on theseus (no worktrees), run unit tests inline, gate via Slurm.
  **Commit 1 (blanket, `f59581c`) — parity GREEN 47/47, 0 violations** (array `13816297`→gather
  `13816298`→compare vs `9f9837d`). steel/aluminum exempt + HTS overrides + config exemptions →
  one merged `rate$by_country` (adapter `.s232_blanket_by_country` calls `is_232_exempt` over the
  same `countries` the calc uses → bit-exact, no inversion hazard); calc reads via
  `s232_blanket_metal_rate` (spec-first / imperative-blob-fallback); old exempt-mutate + override
  loops + config loop deleted; `auto_exempt` left on the blob. **Commit 2 (deals)** — `validate_rate`
  additively accepts scope-form `overrides` + a new `floors` layer (the ONLY Plank-0 touch;
  `resolve_rate` untouched, scope/floors entries reader-invisible); adapter `.s232_deal_layers`
  splits the auto/wood deal tibbles by concept (surcharge→`overrides` scope-form, floor→`floors`,
  census-expanding ISO/EU at build time); calc `s232_deal_records` feeds both deal loops (math
  unchanged: floor `pmax(rate−ORIGINAL base,0)`, surcharge flat-replace; `deal$program`→`deal$scope`);
  `op_disable` clears the deal layers in lockstep. Unit gates GREEN: resolve_rate 70, authority_spec
  19, authority_adapter 41, scenario_ops 50. **Commit-2 parity GREEN 47/47, 0 violations** (array
  `13817257`→gather `13817258`→compare `output/parity_results_20260605_162823`). **S2 COMPLETE.**
  **Next = S3** (delete UK annex-deal hardcode, model Taiwan civil-aircraft exemption as a scope, drain
  the last residual blob: `auto_exempt`, `auto_has_deals`/`auto_has_parts`, `wood_furniture_rate`,
  derivatives [stay per decision 8], `has_232`).
- **2026-06-05 — Plank 4a S2 DESIGN LOCKED (no code yet).** Settled the hardest stage via a fan-out workflow
  (5 parallel mappers → 1 architecture-decision agent → 4 slices each designed then adversarially parity-
  verified, 14 agents) + two decisions from John. Outcome: (1) **blanket slices (exempt / metal HTS overrides /
  config exemptions) → ONE merged `by_country`**, NOT `overrides` — the adversarial pass proved a per-country
  read is `resolve_rate(product=NULL)`, which short-circuits both override forms (corrects the plan doc). (2)
  **Deals split by CONCEPT** (John rejected the lumped "deals" bucket): flat product×country surcharge deals →
  `overrides` scope-form `{scope, countries, rate}`; floor deals → a NEW `floors` field `{scope, countries,
  floor}`; the calc expands the scope label at run time and keeps the floor/surcharge math (decision 8), so
  products stay calc-time (no new parity surface). The ONLY Plank-0 touch = an additive `validate_rate`
  extension (accept the scope-form on `overrides` + whitelist `floors`); `resolve_rate` untouched (scope/floors
  entries are reader-invisible). Adversarial pass caught two real blockers the design agent missed: storing
  deals under any existing layer crashes `validate_rate` (whitelist + the overrides `products` requirement), and
  `op_disable` already drains the deal tibbles (`scenario_ops.R:217-219`) so it must be repointed in lockstep.
  Slice order cheapest→riskiest: HTS overrides → exempt (steel/alum only; `auto_exempt` stays on blob, zero
  observable effect) → config exemptions → deals. Full locked design in the "S2 LOCKED DESIGN" subsection.
  **Next = implement slice 1 (HTS overrides) in a worktree, unit-test, hand to John for the live parity gate.**
- **2026-06-05 — Plank 4a S1a + S1b landed (both parity GREEN 47/47); gate-tooling bug fixed.**
  Read-path decision = FULL REPOINT (no shim). **S1a** (`2a2232e`): blanket steel/aluminum/auto base
  rates → each program's `rate$default`; new `s232_spec_rate()` helper (spec-first, blob-fallback for
  specs-less callers). **S1b** (`307401b`): heading programs (copper/mhd/wood/semi) + a dormant
  `pharmaceuticals` program de-blobbed; `compute_heading_gates`/`resolve_heading_rate`/
  `.s232_recompute_has_232` repointed to read program rates off the spec (`HEADING_RESOLVED_PROGRAM`
  map); non-rate gate inputs stay on the residual blob. scenario_ops `set_rate`/`disable` now mutate
  `rate$default`. Both bit-exact at baseline by construction; unit gates green (adapter 31/31,
  scenario_ops 48/48, spec 19/19, parity 22/22). Parity: S1a array `13807774`→compare `13808487`
  (47/47); S1b array `13809706`→compare `13810632` (47/47). **Gate fix** (`134759f`, src/parity.R): the
  `--unweighted` build drops the un-gated weighted/ETR columns the golden carries; `compare_parity` was
  false-flagging them as `schema_missing_column` — now skipped (pattern `^weighted_etr|^etr_|_imports_b$`).
  This was a pre-existing gather-refactor gate bug surfaced by the S1a daily artifacts (4/8/1/1 "violations"
  = exactly the absent weighted columns). **Workflow learned:** the build sources LIVE src at task runtime,
  so develop the next stage in a worktree + cherry-pick once the prior build is done (never edit live src
  mid-build). **Next = S2** (country deals → overrides/by_country; floor_static; the highest-risk stage) —
  detailed handoff in the "Plank 4a — execution notes & handoff" subsection above.
- **2026-06-05 — Daily gather aggregation pushed into the array tasks.** Follow-up
  to the no-monolith gather: each `scripts/build_revision.R` task now writes a
  small `daily_part_<rev>.rds` from the in-memory snapshot after the snapshot is
  built. `build_gather.R` validates the part cache against final intervals,
  weight mode, and snapshot mtimes, then binds it; stale/missing parts (including
  scheduled revisions that shorten the tip interval) fall back to the existing
  snapshot-streaming path. Verified by full `GATHER_ARGS="--unweighted"` Slurm
  run: array `13805179` completed 43/43 tasks (`0:0`; heaviest tasks 3:31-3:36),
  gather `13805180` used `43 precomputed daily aggregate part(s)` and completed
  in 4:11. End-to-end from first array task start to gather completion: 12:54
  including scheduler gaps.
- **2026-06-05 — Gather monolith removed from the check/publish path.** Follow-up
  to the Plank-3 parity bottleneck: daily series already had a per-snapshot
  streaming path, and the quality report was rewritten to stream the same
  `snapshot_*.rds` files instead of loading the combined `rate_timeseries.rds`.
  The deleted legacy `08_weighted_etr.R` path was the last old ETR duplicate; the
  live daily aggregates remain import-weighted. `build_gather.R` now streams
  daily + quality, writes fresh `metadata.rds`, and never assembles the 204M-row
  monolith. `publish_internal.R` publishes per-interval snapshot parquets directly
  (`valid_from=*/rates.parquet`), and `publish_git.R` publishes only daily CSVs.
  Gates: tier-2 gather `13800246` (6:34) + parity `13800247` GREEN 47/47;
  quality equivalence `13800647` proved `STREAMING == MONOLITH`; final no-monolith
  gather `13801477` completed in 6:11 (parity `13801478` submitted).
- **2026-06-05 — Plank 3 landed (parity GREEN).** Section 122 de-blobbed: the blanket rate
  migrated from the `rate$resolved` blob into the structured `rate$default` layer
  (`rate_type='surcharge'`); calc reads it via `resolve_rate(...)$value`, gating on `value>0`
  (≡ old `has_s122`). scenario_ops: new `DEFAULT_RATE_AUTHORITIES` category for s122 (set_rate
  → `rate$default`, disable → 0); s232 stays a blob until 4a. Dropped the dead
  `s122_rates_from_specs` accessor. Commit `d5ed486` (impl) — unit gate 47+19+21 (job 13797714);
  parity 47/47 within tolerance vs tests/golden/9f9837d (array 13797729 → gather 13797730
  `--unweighted` → parity 13797778; snapshot-only early check 13798477 also 43/43). Per John's
  "no half-measures" call this was the FULL structural de-blob, not a Plank-2-style close-out —
  it's the template for s232 (4a) and IEEPA (4b). Observed (separate follow-up, not done): the
  gather still materializes the 204M-row `rate_timeseries.rds` and feeds it WHOLE to the daily
  series, even though a streaming per-snapshot daily path (`build_daily_aggregates_streaming`,
  perf Phase 1) + per-interval publish split already exist — repointing the gather's daily call
  to the streaming path would drop peak memory ~48GB→~1.2GB and is parity-safe (output documented
  identical). See [[gather-monolith-vs-streaming]].
- **2026-06-05 — Plank 2 landed (parity trivially GREEN; no rebuild).** Section 201's
  spec-driven country scope was already shipped on the 301cs branch as "Phase 2e" and is
  present at `9f9837d` (the golden), so the build path is byte-identical and a rebuild would
  be a guaranteed no-op — verified `resolve_country_scope({all, exclude: Canada})` ==
  `setdiff(countries, Canada)` bit-for-bit, and confirmed via `git show 9f9837d` that both the
  adapter scope and the `06:` calc read predate the golden. Net-new work: closed the scenario
  test coverage gap (201 rescope + disable in `tests/test_scenario_ops.R`, mirroring 301),
  documented the Plank-7 fallback coupling on the `06:` hook, and reconciled the plan
  ("`disable:` vocab" lives in `scenario_ops.R::SCOPE_DRIVEN_AUTHORITIES`, not the yaml; the
  specs-less fallback is RETAINED until Plank 7, same as Plank 1). Gate:
  `sbatch scripts/submit_plank2_tests.sh` (scenario_ops + spec + adapter, pure-logic).
- **2026-06-05 — Plank 1 landed (parity GREEN).** Section 301 additive rate relocated to
  the spec's `by_product_tier` (adapter `build_s301_additive_tier`); build reads it back.
  Gate (`scripts/submit_plank1_build_gate.sh`): `--full --core-only` rebuild of all 43
  revisions, then `run_parity_check.R --golden tests/golden/9f9837d` → 47/47 artifacts
  within tolerance (job 13789634). Two gate-process bugs caught + fixed before the real
  run: (a) `--core-only` without `--full` is a no-op rebuild (reuses stale snapshots —
  must `--full` and pre-delete snapshots so a rebuild miss can't false-green); (b) the
  monolithic `rate_timeseries.rds` parity load OOMs at 192G — compare the 43 per-snapshot
  files instead (same data, memory-safe). Fallbacks retained (Plank 7 deletes them).
  Pre-existing/orthogonal: 3 `test_rate_calculation` Russia §232 Annex-II invariant
  failures (untouched code path), and a non-fatal quality-report `$`-on-atomic error.
- **2026-06-04 — Plank 0 landed (verified).** Compositional rate schema +
  `resolve_rate`/`apply_rate_semantics`/`validate_rate` in `src/authority_spec.R`; tests
  green via `sbatch scripts/submit_resolve_rate_tests.sh` (63 + 19 + 20 assertions). Two
  bugs caught by the gate before commit: (a) `overrides` must accept the named-map form the
  existing spec test uses, not only the rich entry form; (b) R `$`/`[[` partial-matching made
  `rate$default` silently grab `default_unlisted_rate` — fixed with an exact-name accessor.
