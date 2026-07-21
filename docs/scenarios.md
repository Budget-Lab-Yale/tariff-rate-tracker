# Scenarios, alternatives, and counterfactuals

> **History.** Two prior mechanisms are gone: the legacy post-build patch engine
> (`config/scenarios.yaml` + `apply_scenarios.R`, deleted in Phase 7) and the
> AuthoritySpec verb/operations API (`src/scenario_ops.R`,
> `TARIFF_SCENARIO_OPS`, deleted in `54cc662` — it never had a production
> caller). The live mechanism is the **config overlay model**, unified
> 2026-06-10 under one registry. "Baseline = the empty scenario."

## The model

Every non-baseline series is a folder:

```
config/scenarios/<name>/
  meta.yaml      kind + description + publish flag
  overlay.yaml   the config DIFF vs config/policy_params.yaml
```

At load time, `load_policy_params(scenario = name)` (or `TARIFF_SCENARIO=<name>`)
deep-merges the overlay onto the baseline config (`.deep_merge_lists()` in
`src/model/policy_params.R`: maps merge field-by-field, everything else replaces
wholesale; `key: ~` deletes a baseline key). The rest of the pipeline runs
unchanged on the merged params, so every downstream column — stacking, daily
series, ETR exports — recomputes consistently.

The registry (`src/model/scenario_registry.R`) reads the folders:

- `list_scenarios()` — names, kinds, descriptions
- `resolve_alternatives_selector('all' | 'alternatives' | 'counterfactuals' | 'a,b,c')`
- `build_scenario_alt_specs(names)` — alt-runner specs whose `pp_override` is
  exactly the pp a `TARIFF_SCENARIO=<name>` build would see

## Kinds

| kind | meaning | how it runs |
|---|---|---|
| `alternative` | methodology/calibration variant (USMCA share modes, `metal_flat`, `dutyfree_nonzero`, `subdivision_r_mid`) | `--alternatives` on the main build → `alt_runner()` → `output/scenarios/<name>/` |
| `counterfactual` | policy what-if (`no_301`, `no_232`, `no_ieepa`, `no_ieepa_recip`, `no_s122`, `pre_2025`) | same runner |
| `scenario` | full named series (`forced_labor`, `new_301`) | main build under `TARIFF_SCENARIO=<name>` / `TARIFF_SERIES=<name>` — persisted snapshots, quality reports |
| `baseline` | `actual` — documentation stub | never run |

## Running alternatives

```bash
Rscript src/pipeline/00_build_timeseries.R --alternatives all
Rscript src/pipeline/00_build_timeseries.R --alternatives no_301,metal_flat
Rscript src/pipeline/00_build_timeseries.R --alternatives counterfactuals --alternatives-only
```

Legacy spellings still work (`--with-alternatives` == `--alternatives
alternatives`; `--rebuild-alts <list>` == `--alternatives <list>`). Unknown
names fail loud. Each variant is a full per-revision recalc (counterfactuals
are not cheap column patches anymore — consistency over speed), dispatched
through `alt_runner()` with one fresh subprocess per variant when
`--parallel --alt-workers N` is set.

## Counterfactuals: the authority kill-switch

A counterfactual overlay sets one key:

```yaml
# config/scenarios/no_301/overlay.yaml
disabled_authorities: [section_301]
```

Names come from the config's `authority_columns` map (section_232, section_301,
section_301_content_split, ieepa_reciprocal, ieepa_fentanyl, section_122,
section_338, other). `calculate_rates_for_revision()` zeroes the mapped rate columns just
before stacking (step 7g → `apply_authority_disables()` in
`src/model/rate_schema.R`), so totals and contribution shares recompute on what
remains. Unknown names fail loud; the key is absent in baseline, so baseline
output is byte-identical.

Carried-over limitation (same as the legacy engine): cross-authority effects
computed in earlier steps (e.g. IEEPA floors measured against a 232-inclusive
base) are not re-derived when the other authority is disabled.

Baseline authorities that turn on mid-series must be listed explicitly in any
"pre-2025 only" style counterfactual. `pre_2025` disables `section_338` (the
2026-08-19 Canada +50% duty) alongside IEEPA/§122; without that line the duty
would leak into the counterfactual from its turn-on date. Any future baseline
authority added to `policy_params.yaml` must be added to `pre_2025`'s
`disabled_authorities` too.

## Authoring a new scenario

1. `mkdir config/scenarios/<name>` and write `meta.yaml` (pick the kind) +
   `overlay.yaml` containing ONLY the diff vs baseline.
2. Empty overlay == baseline (the `actual` invariant). Unknown config keys are
   inert unless the pipeline reads them — prefer keys the calculator already
   consumes, or add an explicit hook (like `disabled_authorities`) rather than
   patching outputs.
3. `Rscript tests/test_scenario_registry.R` — registry validation is part of
   the suite.
4. For a publishable full series, set `kind: scenario` and build with
   `TARIFF_SCENARIO=<name>`; for sensitivity/counterfactual daily series, use
   `--alternatives <name>`.

## Migration status (2026-06-10)

The seven historical rebuild alternatives were migrated from hand-coded
`pp_override` closures (`build_rebuild_alt_registry()`, now deprecated) to
overlays; `tests/test_scenario_registry.R` pins closure-vs-overlay parity.
The six counterfactuals orphaned by the Phase-7 deletion were resurrected as
`disabled_authorities` overlays with their legacy semantics. Remaining gate
before deleting the deprecated closure registry: a cluster run reproducing
`output/alternative/*.csv` (todo.md, alternatives-unification Step 5).
