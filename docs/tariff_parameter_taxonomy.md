# Tariff Parameter Taxonomy — the abstract essence of a tariff spec

**Status:** living design draft · started 2026-06-04 (John + Claude) · WIP

> Goal: enumerate *every fundamental parameter type* a tariff authority needs in
> order to reproduce the current output, say *where each lives today*, and mark
> *whether AuthoritySpec can represent it*. This is the contract the "make the
> rate field real" work fills. If the taxonomy is wrong, the refactor reproduces
> the mess in a new shape — so we get this right first.

## The abstract essence

A duty-imposing authority is, at root, **one function plus a combination rule**:

```
duty(product, country, date)
   = [ is the (product, country) in SCOPE, and is the authority ACTIVE on date ? ]
   × RATE(product, country)            evaluated under a rate SEMANTICS (surcharge / floor / passthrough)
   ⊕ STACKED with the other authorities' duties
   ∖ net of CROSS-REGIME treatment (USMCA eligibility, MFN base coupling, exemptions)
```

So every parameter falls into one of these **dimensions**:

| # | Dimension | The question it answers |
|---|---|---|
| 1 | **Identity / legal nature** | which authority, what legal basis (drives stacking + USMCA defaults) |
| 2 | **Product scope** | WHICH goods (HTS lines) |
| 3 | **Country scope** | WHICH origin countries |
| 4 | **Rate — value** | HOW MUCH: the `rate(product, country)` function |
| 5 | **Rate — semantics** | how the value becomes a duty: additive surcharge / all-in floor / passthrough |
| 6 | **Temporal** | WHEN: activation window, scheduled turn-on, sunset, retroactivity, dated overrides |
| 7 | **Stacking / combination** | how this duty combines with others; overlap resolution among programs |
| 8 | **Cross-regime** | USMCA treatment, MFN base coupling, true exemptions (zeroing) |
| 9 | **Physical attribute** | (232 only) metal type + content basis → content-split math |

**Cross-cutting axis — statutory vs adjustment.** Each parameter is either
*statutory* (a fact about the law → belongs in AuthoritySpec) or an *adjustment*
(a modeling assumption — shares, methods → belongs in the separate
`adjustment_params` object). Several mechanisms are *mixed*: a statutory rate
SCALED by an adjustment share (semiconductors, subdivision-r, auto rebate).

## Legend

- ✅ **implemented** in the spec as a real structured field, read by the calculator
- ✅ **implemented** — the adapter populates a real structured field and the
  calculator reads it
- ❌ **absent** — no schema field at all; lives only as calculator control-flow
- 🔧 **adjustment** — not statutory; belongs in `adjustment_params`, not the spec rate

---

## Dimension 4 — RATE (value mechanisms) — FULLY WORKED

This is the richest dimension and the one being filled. Each row is a distinct
*mechanism the current output actually depends on*.

| Mechanism | What it does | Live example | Where today (≈line in `06_calculate_rates.R` unless noted) | Spec field | Status |
|---|---|---|---|---|---|
| **flat default** | one rate for everything in scope | 232 steel 50% | adapter → source/heading program | `rate.default` | ✅ |
| **by_country** | per-origin-country rate | IEEPA recip per country | adapter phase collapse | `rate.by_country` | ✅ |
| **per-product override (HS8 SET)** | named product → set rate | UK deal `4120` 25% | adapter deal layer | `rate.overrides` | ✅ |
| **per-product tier (file)** | product list carries 7.5/25 | Section 301 lists | adapter resolves both stacking flavors | `rate.by_product_tier` | ✅ |
| **product rate-override file (coalesce)** | per-product LOWER/higher rate, not exclusion | fentanyl potash carve-out | `coalesce(carveout_rate, fent_rate, 0) :1311` | `rate.product_overrides_file` (doc) | 🟡 |
| **product × country deal** | program's products × a specific country → rate | 232 EU/JP autos 15% | `deal$rate :1860/:1912` | `rate.overrides` + `{active, applies_to}` (doc proposes) | 🟡/❌ partial |
| **default-for-complement** | rate for every country NOT explicitly listed | IEEPA universal 10% | `attr(ieepa_rates,'universal_baseline') :1015,:1091` | `rate.default_unlisted_rate` (`adapter:122`) | 🟡 |
| **per-country dated surcharge** | permanent extra, `pmax` over base mechanism | Russia 200% aluminum | `country_surcharges :2152,:2195` | — | ❌ |
| **date-bounded country override** | TRQ/quota exemption with expiry | `section_232_country_exemptions` | (config + calc gate) | — | ❌ |

### Dimension 5 — RATE SEMANTICS (the *type* attribute, orthogonal to value)

| Type | What it does | Where today | Spec field | Status |
|---|---|---|---|---|
| **surcharge** | additive `+X%` on top | most authorities | `ieepa_type=='surcharge'` | 🟡 (implicit in blob) |
| **all-in floor (`target_total`)** | `pmax(0, rate − base)` — a *minimum total*, not an add-on | autos eu27 15%; IEEPA floor `:1175`; Annex-3 `:2108`; deal floor `:1860` | `rate.target_total` | 🟡 |
| **passthrough** | base-rate only, no additional duty | IEEPA high-duty floor countries | `ieepa_type=='passthrough'` (`05:282`) | ❌ (three-way switch not a field) |

> ⚠ **Floor is not one thing.** A floor needs two more parameters: *which base
> does it floor against* (MFN base) and *when is it computed* — 232 deal floors
> are computed once against the **original** base (`:1860`) and **not** recomputed
> after MFN exemptions; only IEEPA-recip (`:1175`) and Annex floors recompute
> against the **post-MFN** base. So `target_total` implies `{floor_base, floor_timing}`.

### Rate mechanisms that are ADJUSTMENT, not statutory rate (🔧 → `adjustment_params`)

These *scale* a statutory rate by a modeling share — the statutory part (the
default rate, the product list, the floor) is spec; the share is adjustment.

| Mechanism | Math | Where |
|---|---|---|
| semiconductor qualifying/end-use blend | `heading_rate × qualifying_share × (1 − end_use_share)` | `:1584` |
| auto rebate | `pmax(rate − rebate_deduction, 0)` | `:1793` |
| subdivision-(r) certified/FTA blend | 3-way mix | `:2246` |
| metal-content share | `rate × (nonmetal_share)` | `stacking.R` |
| MFN-exemption share | reduces `base_rate` | `:2456`-ish |

---

## The gap taxonomy (for dimension 4/5)

- **(A) Structured value layers** — `default, by_country, overrides, target_total,
  by_product_tier, product_overrides_file, default_unlisted_rate` are populated
  by the adapter. Sentinel strings and raw payload slots are rejected by validation.
- **(B) Absent from schema** — `per-country dated surcharge` (Russia),
  `date-bounded country override` (TRQ exemptions), `rate_type` three-way switch,
  `floor_base/floor_timing`: the schema needs *new fields*.
- **(C) Misfiled** — the blend/scaling mechanisms are statutory-rate-shaped but
  are really `adjustment_params`; keep them out of the spec rate, wire the
  statutory half (rate + scope + floor) into the spec and the share into adjustment.

---

## Dimension 6 — TEMPORAL (two time axes + the splitter) — FULLY WORKED

Timing is a *big* dimension, and the subtlety is that the model has **two time
axes** that are easy to conflate.

### The two axes

1. **The revision timeline** — the discrete dates at which a new HTS archive is
   published and parsed. This is the model's **input / sampling** axis. The rate
   panel is interval-encoded (`valid_from`/`valid_until`) and **held flat between
   boundaries** — it can only *change* at a boundary.
2. **The spec's `active.{from, until}`** — a per-authority/program activation
   window. *Not* a timeline of its own — a **predicate evaluated against a date.**

They interact by **evaluation**: the spec is built per revision, and `active` is
tested as-of a date. A revision is where the *spec* changes (new inputs); an
`active` edge is where the *output* changes **without** new inputs.

### Rates are a staircase; the splitter decides where the steps go

The tariff over time is a **step function** — flat, then a jump on a date, flat,
jump. A step (interval boundary / "frame") is needed on **every date a rate
changes**. Miss one and the panel reports the old rate too long.

### Old rule (subtract-and-forget) vs new rule (remember-and-re-read) — the crux

- **Old / current:** date-gates only **subtract**. When a revision's parse sees
  "pharma effective Sept 1," `filter_active_ch99` *drops* it (not yet effective)
  and **forgets** it. Nothing schedules a return. If no revision lands on Sept 1,
  pharma **never turns on** — the model has amnesia. → **the silent hole.**
- **New:** the parse **records** "pharma — `active.from = Sept 1`" in the spec.
  The splitter **scans the spec, finds Sept 1, makes it a step**, and on Sept 1
  **re-reads the same spec** as-of that date → pharma on. No revision needed on
  Sept 1; the instruction was carried forward in the spec and the splitter
  executed it.

> **One line:** old = dates *subtract-and-forget*; new = the spec *remembers*
> future-dated facts and the splitter *re-reads* it on each remembered date.

### What this does to "the revision as the main unit"

The revision secretly plays three roles; the splitter separates them:

| Role | Today | End-state |
|---|---|---|
| input vintage (archive → spec) | revision | **still the revision** |
| computation | `calculate_rates_for_revision` | `evaluate spec as-of date D` |
| timeline frame (where panel changes) | revision (≈1:1) | interval between **any** two boundaries |

So **one parse can project onto many frames** (one May spec → May / July / Sept
frames). The revision stays the unit of *input*; the timeline's unit becomes the
*interval*, and frames outnumber revisions. The latest spec before a future date
"owns" that date's edges (matches today's "synthetic revision built on the tip").

### Worked example — with vs without the splitter

Setup: **rev_8 (2026-05-22)** archive encodes s122 active + pharma with offset
**2026-09-01**; s122 expires **2026-07-24**; no real revision before the horizon.

- **WITHOUT (today):** rev_8 parse drops pharma (forgotten) → panel `[05-22, horizon)`.
  The `09` splitter cuts at 07-24 (s122 off after). **Pharma never renders** unless
  you hand-author a synthetic activation. ❌ hole.
- **WITH (unified):** one rev_8 parse → `spec_8` carries `s122.until=07-24`,
  `pharma.from=09-01`. Boundaries `{05-22, 07-24, 09-01}`. Evaluate `spec_8` as-of
  each → **three frames**, pharma on from 09-01, **all from one parse, no hole.** ✅

### Three boundary mechanisms today (not unified) → one

| Edge kind | Drawn by today |
|---|---|
| input change | real revision dates (build loop) |
| expiry | `09` post-hoc splitter (`collect_expiry_adjustments`; s122/Swiss) |
| future turn-on | hand-authored synthetic revision (`scheduled_activations`, `00`) |
| mid-interval Ch99 offset | **nobody → silent hole** |

The **unified splitter** = one function builds one sorted list of *every* edge
(`revision dates ∪ active.from ∪ active.until ∪ expiries ∪ Ch99 offsets ∪ scenario
effective_from`) and cuts at all of them. One list, one cutter, nothing missed.

### Build state — mostly built, on a leash 🟡

`src/model/timeline.R` (115 lines, unit-tested) already implements it:
- `collect_schedule_boundaries()` — **comprehensive collector** (knows IEEPA
  invalidation + s122/Swiss + spec `active.from/until`). Built + validated.
- `timeline_split_points()` — the splitter. **Wired live at `09:330`.**
- `expiry_boundaries()` — the **parity bridge** (legacy s122/Swiss only).

It is **fed only `expiry_boundaries()` today** (`09:326`), so it reproduces the
legacy output exactly (parity-green). The comprehensive collector is **built but
not fed**, on purpose — turning it on is a *behavior change* (adds frames), not
parity-safe by construction. Remaining work, **per edge-type**:
1. feed the comprehensive boundary set, AND
2. wire the matching **state-change** at each new boundary (a cut on the right date
   with the *wrong rate* is worse than no cut — e.g. IEEPA invalidation needs its
   zeroing keyed to the boundary, not the revision date; `09:318-324`), AND
3. validate the new frames **without a parity net** (output changes by design; some
   carry open modeling questions, e.g. invalidation `02-20 vs 02-24`).

> **Effort:** the engine is ~90% built and tested. What's left is *turning it on
> one edge-type at a time*, gated on correctness/judgment (days per edge-type), not
> construction. The scary part — building a new timeline engine — is done.

### Same disease as rate & stacking

Timing is the third instance of **"declared but not obeyed":** the spec *names*
`active.from/until`, but only `active.until` (IEEPA invalidation) is truly wired;
activation still flows through `filter_active_ch99` + heading gates keyed to the
*revision* date, and expiries through the separate `09` splitter. The cure is
identical — make the declared field the single source of truth and retire the
scattered mechanisms.

---

## Dimensions 1–3, 7–9 — TO POPULATE (stubs)

_(known mechanisms listed; to be worked the same way as dimension 4)_

- **1 Identity** — authority id; legal nature drives stacking-class + USMCA defaults (declared constants, `adapter`). Mostly ✅ structural.
- **2 Product scope** — `chapters | prefixes | list_file | products_file`, `exclude_file`; tiered subsets (wood softwood vs furniture); precedence (file wins). Partly ✅ (scope is structured), partly in calc.
- **3 Country scope** — `include: all|codes`, `exclude: codes/file`; groups (eu27, swiss). ✅ for 232/301/201; IEEPA scope still hardcoded in calc (CA/MX `:1091`, floor groups `:1020`).
- **7 Stacking** — `class ∈ {additive, content_split, primary_metal, primary_full}` ✅ declared; `exceptions` (China-fentanyl) ✅ declared but calc ignores (`stacking.R:145`); program **overlap resolution** (exclusions-first, highest-rate-wins, replace) ❌ remains calculator-specific.
- **8 Cross-regime** — `usmca_treatment` ✅ declared (but calc recomputes from annex membership, not the flag); MFN base coupling ❌ (no `mfn` rate, floors subtract `base_rate` directly); true exemptions (Ch98 9802 zeroing vs rate-override) — must stay distinct from rate-override files.
- **9 Physical (232)** — `metal.{type, content}` ✅ in schema; drives content-split.
