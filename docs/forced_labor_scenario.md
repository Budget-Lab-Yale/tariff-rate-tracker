# Section 301 forced-labor scenario

**Status (2026-06-06, autonomous night run): code complete + unit-green, UNCOMMITTED.**
Approved plan: `~/.claude/plans/dapper-singing-pearl.md`. This is the first user of the
new overlay-based scenario harness.

## What it models

USTR's proposed Section 301 "forced labor" action (FRN 91 FR 34272, 2026-06-05): an
additional ad-valorem duty on **all products of 60 economies** except an Annex A
exclusion list, at two tiers — **10%** (14 economies with a forced-labor import ban /
Agreement-on-Reciprocal-Trade commitment / partial regime: Argentina, Bangladesh,
Cambodia, Canada, Ecuador, El Salvador, EU, Guatemala, Indonesia, Malaysia, Mexico,
Pakistan, Taiwan, UK) and **12.5%** (the other 46, incl. China, Hong Kong, Vietnam).
PROPOSED, not law — modeled as the successor to the §122 10% blanket, turning ON
**2026-07-24** (the first day after §122's 2026-07-23 expiry).

## How it's built (the scenario harness)

A scenario = baseline `config/policy_params.yaml` **deep-merged** with
`config/scenarios/<name>/overlay.yaml` (`src/model/policy_params.R`), written to an isolated
`data/timeseries/<name>/`. `--scenario actual` (or unset) = the baseline, byte-identical.

The forced-labor authority `section_301_forced_labor` is a **content-split**
(displaced by §232) + **USMCA-eligible** clone of `ieepa_reciprocal`: per-country
two-tier rates from the overlay rosters, all products minus Annex A
(`resources/s301fl_exempt_products.csv`, ~1,632 hts8). It is built **only** when the
config carries the block (so it's absent in baseline) and is **date-gated** to its
`effective_date` — so it's dormant before 2026-07-24 and in every pre-date synthetic
mint, and `rate_s301fl` is dropped from those panels (baseline stays byte-identical,
no `RATE_SCHEMA` change, no golden re-freeze). The 2026-07-24 turn-on is materialized
by `boundary_overrides: ['2026-07-24']` → `build_boundary_mints` (empty-ops mint; the
date-gate fires). Because the gate is by **date**, later empty-ops mints
(`bnd_2026-11-10` cranes/chassis) and the pharma `sched_` mint also carry it.

## How to RUN it

From a **login shell** (not inside a small interactive alloc — the list-revisions step
needs >5 GB):

```bash
SCENARIO=forced_labor bash scripts/submit_build_array.sh
```

This generates an isolated timeline (`output/build_array_timeline_forced_labor.rds`,
includes `bnd_2026-07-24`), array-builds every revision into
`data/timeseries/forced_labor/` with the overlay merged, and runs the gather/daily.
Baseline `data/timeseries/` is never touched (guarded). Then validate / spot-check the
`data/timeseries/forced_labor/` daily series at 2026-07-25: China (non-annex) → +12.5%
content-split with s122=0; a 10%-tier origin → +10%; an Annex-A hts8 → 0; a non-covered
origin → 0; a USMCA-eligible CA good → 0.

## Build result (2026-06-07) — DONE + verified

Full isolated build succeeded (array 47/47 + gather). Snapshots: `data/timeseries/forced_labor/`.
Daily series: `output/scenario_forced_labor/actual/daily/` (isolated — see incident note below).
Daily spot-check of `daily_overall.csv`:
- **Turn-on:** weighted ETR `0.1171 → 0.1208` at 2026-07-24 — a small net rise because forced-labor
  *replaces* the expiring §122 10% blanket (the successor framing), not an additive +11pp.
- **Date-gate persists:** forced-labor stays on across `bnd_2026-11-10` (wADD ~0.109), which an
  op-activated tariff would not — this is exactly why it's date-gated.
- It also surfaced the **pharma bug** (wADD `0.1121 → 0.1092` at 2026-11-10 = pharma vanishing at the
  empty-ops mint — see below).

### ⚠️ Incident + harness fix (daily-output isolation)

The first scenario gather wrote its daily series to the **baseline** `output/actual/daily/` because
`save_daily_outputs()` uses `actual_daily_dir()` (= `output_root()/actual/daily`), which `TARIFF_TS_DIR`
does **not** redirect. `scripts/build_gather.R` now sets `TARIFF_OUTPUT_DIR=output/scenario_<name>` for a
scenario so daily/ETR land in `output/scenario_<name>/...`. The clobbered baseline daily was restored
from the 06-04 golden (`output/parity_golden/actual/daily`), which is **stale** vs the current baseline
(it ends at `2026_rev_7`; the live baseline has more revisions + synthetics). **Action for John:** refresh
`output/actual/daily/` by re-running the baseline gather — `data/timeseries/` baseline snapshots and the
golden were never touched, so it's a quick daily regen.

## Verified so far

- `tests/test_forced_labor_scenario.R` — 31/31 (deep-merge, overlay load, two-tier
  by_country, date-gate, stacking-policy invariant).
- `test_policy_from_specs` (updated 8→9 authorities) and `test_stacking` — green.
- All 60 economies map to the correct census codes (verified individually).

## Caveats / open items

- **Annex A ≈ 1,632 hts8** (zlib-inflated from the FRN PDF; poppler module wouldn't
  load here). ~27 fewer than a clean poppler `-layout` pass (line-wrap artifacts) —
  a minor refinement. The ~574 `Ex`/`Aircraft` partial-scope lines are treated as
  full 8-digit exclusions (slight over-exclusion).
- **Deferred (FRN carve-outs):** CAFTA-DR duty-free textiles from the 6 named
  countries; the proposed reduced-rate "textile mechanism"; informational
  materials/donations/baggage (not HTS-addressable).
- The full end-to-end scenario build had not completed at write time — the engine is
  unit-tested but the multi-revision build + daily spot-check is the final gate.

## ⚠️ Likely pre-existing baseline bug found (pharma, NOT forced-labor)

The pharma §232 activation (`sched_pharma_2026_09_29`, an op `set_rate
section_232 pharmaceuticals`) is **op-activated**, but the gather mints
`bnd_2026-11-10` (cranes/chassis) with **empty ops** by re-stamping the tip — so the
pharma `set_rate` op is **not** applied there, and pharma's `rate_232` reverts to 0
from 2026-11-10 onward in the **baseline** series. Forced-labor avoids this by being
date-gated (fires on every mint ≥ its date regardless of ops). Pharma needs the same
date-gate treatment, or the boundary mints need to carry cumulative scheduled ops.
Also: `test_rate_calculation.R` has 3 failing assertions (Russia annex_2 / steel /
Note-39a) that are committed §232-annex checks unrelated to this work — flagging in
case they're unexpected.
