# Phase 6 — Embed/Seed (the linchpin): make 232 / IEEPA / s122 spec-authoritative

> **⚠️ Re-verify before executing.** Line numbers drift; **code wins over this doc**. This plan
> was synthesized from a 5-agent recon of the *actual* code on 2026-06-03 (run
> `wf_d607f8c4-099`), then hand-checked. Re-grep each anchor before editing. The Phase-3
> resolved-program contract and the Phase-2 spec wiring are assumed — re-confirm.

## Why this phase (the capability it unlocks)

Today a scenario can only re-scope the *small* country-specific authorities (301, 201 — shipped
in Phase 2e). The *big* tariffs — Section 232 (steel/aluminum/autos/copper/…), the two IEEPA
tracks, and Section 122 — cannot be changed in a what-if, and no brand-new tariff can be authored.
The reason is mechanical: the calculator reads those authorities' **rates** from the *embedded raw
objects* (`raw_s232` / `raw_ieepa` / `raw_fentanyl`) or, for s122, **re-extracts them from Ch99
entirely, ignoring the spec**. The normalized `programs` fields the adapter scaffolds are inert.

Phase 6 moves the rate data into the spec's `programs` (mutable by the ops engine) and points the
calculator at it — then `set_rate`/`set_floor`/`add_program` become possible for these authorities,
and the Phase-1 adapter can finally be deleted ("baseline = the empty scenario").

## Verified current embed-state (per authority)

| Authority | Rate source today | Scope | Activation | Spec read? |
|---|---|---|---|---|
| **section_232** | `attr(...,'raw_s232')` (21-field list, `05:1033-1055`), read across step-4/5 (`06:1353-2160`) | embedded exempt lists / overrides | `heading_gates` **already** spec-precomputed (Phase 2c, `06:1379`) | rate=embed-read; heading-gates=spec; `programs` inert |
| **ieepa_reciprocal** | `attr(...,'raw_ieepa')` tibble + `universal_baseline` attr (`06:756`, consumed `06:829-1205`) | `country_scope` inert | `active$until` **LIVE** from spec (Phase 2d, `06:809`) | rate=embed-read; until=spec |
| **ieepa_fentanyl** | `attr(...,'raw_fentanyl')` tibble (`06:758`, consumed `06:1207-1313`) | `country_scope=c(CN,CA,MX)` **inert** | none (rides reciprocal's `until`) | **no spec field read at all** |
| **section_122** | **`extract_section122_rates(ch99_data)` at `06:2406` — ignores the spec entirely** | inert | `pp$SECTION_122` date gate (`06:2408`) | **none** |
| section_301 / section_201 | ch99-derived rate; **scope LIVE** from spec (`06:2333`/`06:2476`) | spec-authoritative | — | scope only (Phase 2e) |

The footnote-seed (`calculate_rates_fast`, `06:56-194`, runs `06:791`) produces panel rate columns
from Ch99 footnote refs but **never writes back into the spec**. No `add_program`/`set_rate` verbs
exist (`scenario_ops.R:29` lists only 301/201 as scope-driven; `:61-63` fails loud on the rest).

## Architectural decisions (made here — no code choices go to the PM)

1. **Reconstruction-shim, not body-rewrite.** The dense calc bodies (IEEPA step-2 ≈ 300 lines;
   232 step-4/5 ≈ 700+) stay **untouched**. We populate the `programs` with the rate data and, at
   the calc head, **rebuild the exact legacy-shaped local** (`s232_rates` 21-field list; the
   `ieepa_rates` tibble + `universal_baseline`; the fentanyl tibble; the s122 list) *from the
   program fields*. The body consumes the same-shaped object → byte-identical.
2. **Keep the byte-identity bar** (don't relax to tolerance). Each cutover is gated behind a
   transitional `stopifnot(identical(reconstructed, raw))` in the calc; once the parity slice is
   green we delete the raw embed + the assert. Because reconstruction is proven `identical`, the
   panel stays byte-identical after deletion. (`validate_phase1_compare.R` already reports both
   `identical()` and the tolerance comparator.)
3. **Thin cut for IEEPA, not full normalization.** Relocate the resolved IEEPA tibble (+baseline)
   from `attr` into `programs[[1]]$rate` and read the calc's *input table* off the program; leave
   the phase/floor/Swiss/country-EO math where it is. Full per-EO normalization is **deferred**
   (Phase 8 polish) — it adds no capability the ops engine can't already get by mutating the
   program's rate table, and the recon flags it as the single highest drift risk.
4. **232 thin cut too.** Enrich the 7 programs to carry the rate payload, rebuild the 21-field list
   via `s232_rates_from_specs()`. Full per-metal-program normalization (each metal its own program
   with its own rate, cleaner for ops) is **deferred to Phase 8**; the thin cut delivers the
   "bump steel" capability now at far lower risk.
5. **Sequence by safety**, lowest blast radius first; 232 last because it gates adapter deletion.

## Sub-steps (each shippable + parity-gated, Phase-2 cadence)

- **6a — s122 embed-read** *(low)*. Bring s122 up to the same embed-read footing as the other three:
  the adapter embeds `raw_s122` (= `extract_section122_rates(filter_active_ch99(ch99_data, eff_date))`
  — the *same* date-gate the calc applies at `06:766`, mirroring the s232 heading-gate precompute at
  `adapter:120-123`); the calc at `06:2406` reads it back when `specs` is non-NULL instead of
  re-extracting. Closes the "s122 ignores the spec" gap. **Gate:** byte-identical slice incl.
  `2026_rev_4` (s122-active, post-invalidation). *Files: `authority_adapter.R` (SPEC_RAW_ATTRS,
  embed, `specs_legacy_args`), `06_calculate_rates.R:2406`, `tests/test_authority_adapter.R`.*
- **6b — relocate the four raw objects into `programs` + reconstruction shim** *(medium)*. Move
  `raw_s232`/`raw_ieepa`/`raw_fentanyl`/`raw_s122` from `attr()` into the owning program's `rate`
  field; the calc head (`06:755-759` + `:2406`) rebuilds the legacy locals from the program via
  `*_from_specs()` helpers, guarded by `stopifnot(identical(...))`. Deletes the `SPEC_RAW_ATTRS`
  contract. **Gate:** byte-identical slice; then drop the asserts. *This is the step that lets the
  dual signature die.* For s232 carry the **`has_232` OR-gate**, deal tibbles (col set/types/row
  order), named-list overrides (census-code names), derivative fallbacks, and exempt `character(0)`
  exactly — these are the recon's named drift risks.
- **6c — decouple 232 heading-gates from live Ch99** *(low-med)*. The only remaining Ch99 grep in
  `compute_heading_gates` is `auto_parts` (`06:208`, `^9903\.94\.0[5-9]`); lift it into the adapter
  (which already holds `ch99_data` at `adapter:121`) and store on the gates. **Keep the heading-gate
  keys = `section_232_headings` config names** (autos_passenger, auto_parts, …) or the fail-closed
  guard at `06:1386-1393` throws (the 7 spec programs are coarser than the ~10 gate keys — do NOT
  remodel programs at heading granularity). **Gate:** byte-identical, heavy-232 revs (`2026_rev_5`).
- **6d — ops verbs for the big authorities** *(medium — the capability)*. Add
  `set_rate`/`set_floor`/`set_exempt`/`add_program` to `scenario_ops.R`; add 232/ieepa/s122 to the
  supported set. **No baseline change** (verbs only fire under a scenario). **Gate:** baseline still
  byte-identical + a positive test ("bump steel → only `net_232` moves on covered rows").
- **6e — wire `apply_operations` into the 09 daily-series build site** *(low, correctness)*. The
  second build site (`09:1185`) builds specs but **never calls `apply_operations`** (unlike
  `00:124-129`) → scenario daily output is silently baseline-only. Fix so daily honors ops.
- **6f — delete the adapter / collapse the dual signature** *(high — final)*. Once nothing reads
  `raw_*` and everything reads `programs`, retire the re-packaging in `build_authority_specs`,
  `SPEC_RAW_ATTRS`, `specs_legacy_args`, the calc's `:755-759` head and the `specs==NULL` branches
  (`:775`,`:1338`,`:2406`); the parser emits specs directly; "baseline = empty scenario." **Gate:
  the FULL 41-revision sweep** (incl. annex revs) byte-identical before deleting.

## Global risks / traps (from recon, must respect)

- **`universal_baseline` survival** (`06:965`, set `05:442`): an out-of-band SCALAR on the IEEPA
  tibble. Promote it to an explicit program field; **NULL is the correct empty, not 0/NA** (guard is
  `!is.null && > 0`). Losing it silently drops the universal 10% on every unlisted country.
- **NULL-vs-NA on `active$until`** (`06:814`): coercing NULL→NA makes `if (NA && …)` error. Mirror
  `pp$IEEPA_INVALIDATION_DATE` verbatim (already done Phase 2d).
- **`has_232` OR-gate** (`05:1019`): TRUE on deals-only/derivative-only revs even when a base rate is
  0. Reconstruct from the same OR, not a per-program `rate>0`.
- **Fentanyl `active$until` is INERT** (set at `adapter:147`, never read — calc uses reciprocal's at
  `:810` for both). Don't assume it does anything; the China-additive flip comes from
  `default_stacking_policy()` (`stacking.R:146`), NOT the spec exception (two sources of truth —
  unify only if a fentanyl re-scope scenario needs it; not required for rate parity).
- **Two build sites out of sync** (`00` applies ops, `09` does not — see 6e). Any embed/seed change
  must land in BOTH extract→spec paths or daily diverges.
- **`validate_phase1_compare.R` only diffs `snapshot_<rev>.rds`** — a change in a daily/timeseries
  artifact or a list-column is not caught. If a step touches the `09` path, run daily parity too.
- **s122 gate-convention triple** (calc `<= expiry` inclusive vs spec `until` exclusive vs helpers.R
  strict `>`): keep the calc gate on `pp$SECTION_122` for 6a; only reconcile when `set_active` for
  s122 lands (and then re-point the helpers.R expiry zeroing too, or scenarios diverge).

## Validation flow (per step)

```
# fast inner loop (≈2 light revs, ~3 min):
sbatch output/validate_specs_slice.sh                       # REVS default: rev_20 2026_rev_4
# heavy 232 / annex coverage (6b/6c):
REVS="2026_rev_5 rev_20 2026_rev_4" sbatch output/validate_specs_slice.sh
# 6f only — full sweep before deleting the adapter:
REVS="$(Rscript scripts/list_revisions.R)" sbatch output/validate_specs_slice.sh
```
`validate_specs_slice.sh` builds `TARIFF_USE_SPECS=1` snapshots into `data/timeseries_specs/` and
runs `validate_phase1_compare.R` vs the serial golden in `data/timeseries/` (reports `identical()`
**and** tolerance). Run via **sbatch**, never the login node.

## Adapter-deletion gate (the end-state condition)

The Phase-1 adapter can be deleted only when **no code reads `attr(...,'raw_*')`** — i.e. 6a–6c
done for all four authorities + heading-gates — AND `09:1185` applies operations (6e). Then
`SPEC_RAW_ATTRS`, `specs_legacy_args`, the `:755-759` head, and every `specs==NULL` branch collapse
together, gated by the full 41-rev byte-identical sweep.

---

## EXECUTION OUTCOME (2026-06-04) — Phase 6 done through the byte-gated core

Executed unattended; every refactor step gated byte-identical on Slurm before commit. Commits on
`phase0-parallel-build` (pushed):

| step | commit | what | gate |
|---|---|---|---|
| 6b-i | `bb97fa7` | relocate raw_s122 → `programs[[1]]$rate$resolved` (verbatim thin cut) | rev_20 + 2026_rev_4 byte-identical |
| 6b-ii | `72eac7d` | same for s232 / ieepa_reciprocal (universal_baseline rides along) / fentanyl | + 2026_rev_5 heavy annex, byte-identical |
| 6b-iii | `a4aea8e` | drop the transitional `raw_*` attrs + `SPEC_RAW_ATTRS` + `specs_legacy_args` + asserts | heavy slice byte-identical |
| 6c | `9ee9dfa` | decouple 232 heading-gates from live Ch99 (`auto_has_parts` → s232_rates; gate fn now pure) | heavy slice (rev_20 auto_parts-active) byte-identical |
| 6d | `ac94824` | ops verbs `set_rate` / `set_exempt` / `disable` for the big authorities | bump-steel real-grid proof + baseline byte-identical; tests 24/24 |
| 6e | `d51e047` | the 09 rebuild path (`build_alternative_timeseries`) honors scenario ops | baseline slice byte-identical + parse-check (no daily-parity infra) |
| 6f-core | `9c960b9` | AuthoritySpec path ALWAYS-ON; retire `TARIFF_USE_SPECS` | **FULL 41-rev sweep ALL byte-identical** |

**Design notes vs the plan above:** the thin cut stored each parser object *verbatim* in
`programs[[1]]$rate$resolved` (reconstruction = identity ⇒ byte-identical by construction), so the
recon's "named drift risks" never materialized — they apply to *full* per-program normalization, which
stays deferred. 6c lifted the `auto_parts` grep into `extract_section232_rates` (cleaner than the
adapter, equivalent date-gated input). 6d delivered `set_rate`/`set_exempt`/`disable` (the headline
capability); IEEPA per-country `set_rate` + `set_floor` are fail-loud follow-ups.

**6f scope decision (deliberate):** only the high-value, byte-gated CORE landed (specs = production
default). The remaining collapse — **remove the bespoke positional args from
`calculate_rates_for_revision`'s signature + delete the `build_authority_specs` adapter +
parser-emits-specs** — is **DEFERRED**: it is capability-neutral, coupled to the deferred full
per-program normalization (decisions #2/#3), and its blast radius is 9 unit-test call sites that the
snapshot gate cannot see (so it sits outside the unattended byte-gate safety envelope). The dual
signature + adapter therefore remain in place; baseline is unaffected.

## Beyond Phase 6 (same run)

- **Phase 7 (`6d1ff0c`)** — deleted the legacy YAML scenario engine (`apply_scenarios.R`,
  `config/scenarios.yaml`, `run_post_build_scenarios_per_revision`, the orphaned
  `split_rev_intervals_at_patches`); slimmed `run_alternative_series` to drive only the retained
  USMCA-share rebuild-alts; rewrote `docs/scenarios.md` + `docs/build.md` (`61425b8`). Gate: slice
  byte-identical + dangling-ref scan clean.
- **Phase 8a (`a168cd2`)** — new-coverage machinery: `add_program` verb + the no-Ch99 seeder
  (`src/new_coverage.R`, rides `rate_other`, injected at 06 step 7b). Dormant in baseline. Gate: a
  CLEARLY-SYNTHETIC drone tariff (+50% on HTS 8806) moved `rate_other` +0.50 on all 2,640 covered pairs,
  nothing else; no-ops byte-identical. Tests 37/37.
- **Phase 8b (`370f8f3`)** — fork-#2 loud weight report in `08`: rated pairs lacking a 2024 import
  weight are reported per date, never fabricated (message-only; ETR math unchanged).

## Working output produced

Real per-revision snapshots, including two capability demonstrations on `rev_20` (gitignored builds):
- `data/timeseries_specs_full/` — all 41 revisions, specs-always-on, byte-identical to the golden.
- `data/timeseries_6d/{base,steel}/` — bump-steel: `rate_232` 0.50→0.99 on China steel (72xx),
  `total_rate` 0.95→1.44.
- `data/timeseries_p8/{base,drone}/` — synthetic drone: `rate_other` 0→0.50 on HTS 8806,
  `total_rate` e.g. China 0.45→0.95, Vietnam 0→0.50.

These are SNAPSHOT (rate-panel) outputs. The downstream daily-series → weighted-ETR → publish pipeline
was **not** re-run end-to-end this session (not required for byte-identical refactor gating, and the
gather→daily/ETR parity harness is still an open Phase-0 infra item — needed to byte-gate 6e/8b
properly). `output/{daily,alternative,actual}/` hold artifacts from the prior 2026-06-03 full build,
not regenerated here.
