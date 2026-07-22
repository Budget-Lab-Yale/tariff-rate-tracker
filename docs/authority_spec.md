# AuthoritySpec — a unified authority parameter schema for counterfactual scenarios

**Status:** design proposal (revised) · **Date:** 2026-06-03

> **Resolved design decisions** (see also the review that produced them):
> 1. Supports all four scenario kinds — disable, rate bump/floor, **re-scope to new
>    countries**, and **add new coverage**. The last two require recompute, not panel edits.
> 2. A scenario is a **synthetic future revision**; only intervals at/after its
>    `effective_from` are recomputed (dates before are reused baseline unchanged).
> 3. **Statutory scope only.** ETR adjustment knobs (USMCA utilization, auto rebate,
>    metal-content method, subdivision-r, de-minimis) live in a separate
>    `adjustment_params` dimension. A scenario = `{policy} × {assumptions}`.
> 4. Migration parity is **numeric tolerance**, not byte-identical.
> 5. Scenario files use **Census codes** (validated; fail loud on unknown), with two
>    distinct alias namespaces resolved to sets: **authority-group** aliases (`ieepa`
>    → reciprocal + fentanyl) and **country-group** aliases (`eu27`; `swiss` →
>    {Switzerland, Liechtenstein}). The two resolve and validate separately.
> 6. **Current law is a time path** (it embeds scheduled future changes). Baseline
>    defaults to **current-law**; **current-policy** is a canned scenario that cancels
>    the IEEPA/s122 sunsets (other scheduled changes — annex restructuring, annex_3
>    sunset — still bend the path). A past `base:` is an **effective-date** cut: include
>    every revision effective on-or-before the pin plus changes already scheduled as of
>    then. The data records only effective dates, not enactment dates, so
>    "enacted-after-pin" is not separable — the pin is defined on effective date.
> 7. IEEPA invalidation stays a per-authority `until`, with an `ieepa` group alias so
>    one operation flips reciprocal + fentanyl together.
> 8. Authored 232 programs that overlap existing coverage resolve by **precedence**
>    (rate-independent exclusions first, then highest-rate-wins among the remainder).
>    A rate *cut* needs an explicit **replace** op — it cannot win a `max`.

## Motivation

Today the Budget Lab tariff pipeline runs three repos:

```
tariff-rate-tracker  →  tariff-etrs  →  tariff-model
(statutory rates)       (ETR engine)     (revenue + macro)
```

This is awkward in two ways: the tracker *also* emits ETR output, so there are
two calculator engines kept in lockstep by hand; and counterfactual scenarios
live downstream in ETRs, where they can only overlay the tracker's *flat*
per-product-country rates — they cannot add new tariff coverage or re-scope an
authority across countries.

The goal is to give **tariff-rate-tracker** first-class counterfactual
simulation, then point **tariff-model** directly at it — dropping the
two-engine overlap. This document specifies the data model that makes that
possible: a single per-authority parameter structure (`AuthoritySpec`) that the
baseline parser *produces* from the HTS JSON and the scenario layer *mutates*,
so that **baseline is literally the empty scenario.**

## Pipeline shape: what "params" means and where AuthoritySpec sits

The word *params* is overloaded in this repo; disambiguate before reading on:

- **parsed params (per-authority data)** — `products`, `ch99_data`, `ieepa_rates`,
  `s232_rates`, `fentanyl_rates`, `usmca`. Produced by the `03/04/05` parsers from
  the HTS JSON. Each authority's object is **a different shape**: `s232_rates` is a
  21-field named list (`05:1033`); `ieepa_rates` is a tibble (`05:214`);
  `fentanyl_rates` is yet another tibble.
- **`policy_params.yaml`** — hand-authored constants (country codes, floor rates,
  232 heading definitions). **Not** parsed from JSON; you edit it directly.

AuthoritySpec normalizes the *parsed per-authority params* (plus the relevant slices
of `policy_params.yaml`) into **one uniform shape**. It does **not** change the
parsing, and it does **not** change the calculator's math — only the calculator's
input interface. The translation runs on **every** build; a scenario is just the
same path with one extra step (apply operations to the specs). That is what
"baseline = empty scenario" means literally.

```
BEFORE
  JSON ──parse(03/04/05)──▶ {ieepa_rates(tibble), s232_rates(list),     ──▶ calculate_rates_for_revision(
        (unchanged regex)    fentanyl_rates(tibble), products, …}            products, ieepa_rates, s232_rates, …)
                                                                              └ each authority = its own block/shape
                                                                         ──▶ RATE PANEL (RATE_SCHEMA, 19 cols)

AFTER (baseline)
  JSON ──parse(03/04/05)──▶ same bespoke structs ──★adapter/normalize──▶ [AuthoritySpec × authorities]
        (UNCHANGED)                                 (NEW)                        │ (no operations)
                                                                                 ▼
                                                    calculate_rates_for_revision(specs, products, countries)
                                                    └ ★NEW signature; reads fields off specs; SAME math/output
                                                                                 ▼  RATE PANEL — identical (parity-gated)

AFTER (scenario)  …specs ──★apply operations──▶ specs′ ──▶ calculate_rates_for_revision(specs′, …) ──▶ counterfactual panel
```

What changes / what does not:

| Layer | Changes? |
|---|---|
| Parsing logic (regex / JSON reading, `03/04/05`) | **No** — untouched |
| `param-object-1 → AuthoritySpec` adapter | **New** |
| Calculator *input interface* (signature + how it reads inputs) | **Yes** — re-plumbed |
| Calculator *math* and *output* (the RATE_SCHEMA panel) | **No** — preserved, parity-gated |

The brittle prose-parsing in `03/04/05` is a real but **separate** concern; folding a
parser rewrite into this migration would conflate two jobs and inflate parity risk.
The adapter wraps the existing parser output as-is (migration step 1 below).

## The core idea: a scenario is a synthetic future revision

The repo's spine is already "on date *D*, the rate panel changes to *X*" — that
is what an HTS revision *is*, and why every downstream artifact (interval
encoding, `delta_*.rds`, daily series, ETRs) is derived from the panel rather
than computed specially.

A presidential announcement effective end of July is functionally **a revision
that USITC has not published yet.** So a scenario is a *hypothetical revision*
layered on the tip of the baseline panel and recomputed forward from its
`effective_from` (dates before are reused baseline, untouched).

**The tip is itself a time path, not a flat rate.** Current law as of any date
already encodes scheduled future changes — but they reach the timeline through
**two different mechanisms today**, which the new engine must unify:

- **Expiries** (s122 sunset, Swiss-framework expiry 2026-03-31) are split into
  sub-intervals *after* the panel is built, by `collect_expiry_adjustments` /
  `get_expiry_split_points` (defined in `src/core/helpers.R:391,469`; invoked from
  `09_daily_series.R`).
- **Activation offsets** (`effective_date_offset`) are handled *earlier and
  differently* — `filter_active_ch99` (defined in `src/model/rate_schema.R:220`, called
  at `06:719`) gates them per revision at calc time. The expiry splitter does
  **not** create a sub-interval at a mid-interval Ch99 activation offset.

So the baseline path *is* multi-interval, but it is **not** one unified splitter
today (an overstatement to avoid). A scenario must therefore *compose* with this
scheduled path, and the synthetic-revision timeline must **explicitly collect every
schedule boundary** into one splitter (see implementation requirements below). This
keeps baseline and counterfactual symmetric: all downstream derivations work unchanged.

### Where the scenario injects: the parameter layer (not JSON, not the panel)

The pipeline has three layers:

```
A. HTS JSON archives                                  ← raw (never synthesized)
B. Parsed parameters: products, ch99_data,            ← THE INJECTION SEAM
     ieepa_rates, fentanyl_rates, s232_rates, usmca
     + policy_params.yaml
C. calculate_rates_for_revision(B...) → rate panel → stacking → daily / ETR
```

`calculate_rates_for_revision()` (`src/pipeline/06_calculate_rates.R:704`) already takes
the Layer-B objects as named arguments. A scenario therefore = **build a
modified Layer-B parameter set and call the same function.** All of Layer C's
logic (metal-share assignment, USMCA scaling, stacking) re-runs on the delta for
free — "the calculator still holds," structurally guaranteed.

We do **not** synthesize fake JSON (Layer A), and we do **not** post-process the
output panel (Layer C). Scenarios change inputs and rerun the calculator.

## The schema

`AuthoritySpec` is one envelope every authority uses. The only genuinely complex
authority is Section 232 (steel, autos, copper… each with its own
products/rate/deals), so we model that as a **list of programs**. Simple
authorities (301, s122, s201) are an authority with exactly one program.

```yaml
section_232:
  stacking:
    class: primary_metal          # default; overridable per program (autos use primary_full)
  usmca_treatment: per_program    # 232 varies by program; others set it here
  active: { from: 2025-03-12, until: null }   # null = open-ended
  programs:
    - id: steel
      product_scope: { chapters: ['72','73'] }
      country_scope: { include: all, exclude: [] }    # country exemptions here
      rate:
        default: 0.50
        overrides: { '4120': 0.25 }                   # UK deal — plain SET (not a floor)
      metal: { type: steel, content: full }           # 232-only block
      active: { from: 2025-03-12 }
    - id: autos_passenger
      product_scope: { prefixes: ['870322','870323', ...] }
      country_scope: { include: all }
      rate:
        default: 0.25
        target_total: { eu27: 0.15, '5880': 0.15 }    # all-in FLOOR: max(value-base,0); JP=5880
      usmca_treatment: eligible                        # statutory eligibility only;
                                                       # content-share scaling → adjustment_params
      stacking: { class: primary_full }                # full customs value, not metal-content split
      metal: { type: none }
      active: { from: 2025-04-03 }
```

The **same envelope** for a "simple" authority — Section 301, with the China
gate now a field instead of a hardcoded `if`:

```yaml
section_301:
  stacking: { class: additive }
  usmca_treatment: none
  active: { from: 2018-07-06, until: null }
  programs:
    - id: s301
      product_scope: { list_file: resources/s301_product_lists.csv }
      country_scope: { include: ['5700'] }    # China; was `if (country == cty_china)`
      rate: { by_product_tier: { "01012100": 0.25, "01012900": 0.075 } }
```

And IEEPA fentanyl — the country-dependent stacking wrinkle, expressed as data:

```yaml
ieepa_fentanyl:
  stacking:
    class: content_split            # scaled by nonmetal_share on 232 products...
    exceptions: { china: additive } # ...except China, which passes through full
  usmca_treatment: exempt
  active: { from: 2025-02-04, until: 2026-02-24 }   # IEEPA invalidation; flip via the
                                                    # `ieepa` group alias (recip + fentanyl together)
  programs:
    - id: fentanyl
      product_scope: { include: all }
      country_scope: { include: ['5700','1220','2010'] }   # CN/CA/MX; freely extendable
      rate:
        by_country: { '5700': 0.20, '1220': 0.25, '2010': 0.25 }
        product_overrides_file: resources/fentanyl_carveout_products.csv
        # NOT an exclusion list — these are per-product LOWER/higher rates (e.g. potash
        # +10%): the engine does coalesce(carveout_rate, fent_rate, 0) (`06:1195`).
        # Modeling it as exclude_file would zero them and understate the rate.
      # True exemptions (Ch98 9802.00.40/50/60/80) are separate — they zero the rate
      # (`06:1230`) and belong in an exempt_file, not here.
```

### Field reference

Every field maps to something the current engine already does — this is a
*normalization* of existing behavior, not new policy.

| Field | Purpose | Where it lives today |
|---|---|---|
| `stacking.class` | `primary_metal` (232, owns the metal-content fraction — **requires a real `metal.type`**) / `primary_full` (232 owns the **full** customs value, IEEPA excluded — for non-metal 232 like autos/drones; no metal block) / `content_split` (scaled by `nonmetal_share` on 232 products — IEEPA recip, s122, CA-MX fentanyl) / `additive` (full rate always — 301, s201, other, China fentanyl) | the `case_when` branches in `src/model/stacking.R` |
| `stacking.exceptions` | per-country-group override of the class — captures "China fentanyl is additive while others content-split" **as data, not a branch** | hardcoded `country == cty_china` in the fentanyl branch |
| `country_scope` | `{include: all \| [list], exclude: [list/file]}` — the set membership the engine iterates (`country %in% scope`) | hardcoded for 301/fentanyl; parsed-as-data for 232/IEEPA |
| `product_scope` | `{chapters \| products_file \| prefixes_file \| prefixes, exclude_file}` — **a precedence, not alternatives**: `products_file` (authoritative CSV) wins; `prefixes_file` / inline `prefixes` are the fallback used only when no file is present (`06:234-290`). (The draft's `list_file` is this `products_file`.) | `section_232_headings`, resource CSVs |
| `rate` | `{default, by_country, overrides, target_total, by_product_tier}` — distinct mechanisms: `overrides` / `by_country` are plain SETs (per-HS8 / per-country); `target_total` is an all-in FLOOR `max(value − base, 0)` where **`base` is the MFN layer** (see "Baseline semantics → MFN/base"); 232 country deals carry a `kind: floor \| surcharge` (`06:1754`); the IEEPA surcharge-vs-floor switch is a country-group case. **Floor timing is not uniform:** 232 deal floors are computed once at step 4c (`06:1750`) against the *original* base and are **not** recomputed after MFN; only the IEEPA-recip floor (6d, `06:2497`) and Annex-III floor (6e, `06:2511`) recompute against post-MFN base. | scattered: `s232_rates`, `section_301_rates`, deal floors (`06:1750`), surcharge/floor switch (`06:964`), ch99 extraction |
| `usmca_treatment` | statutory **eligibility metadata**: `exempt` / `eligible` / `none`. The utilization *math* lives in `adjustment_params`. **Reality note:** on the live share-path this flag is **not** itself a calc input for base/recip/fent/s122 — the per-product USMCA share already encodes eligibility (`06:2524`); and 232-auto eligibility is *recomputed* from annex membership mid-calc (`06:2574`), not read from a static tag. Treat the flag as documentation/validation metadata, not the operative input on that path. | `*_usmca_exception` flags + per-program `usmca_exempt`; utilization/eligibility at `06:2522-2646` |
| `active.{from,until}` | activation window — **what a synthetic revision sets**; `until` also models IEEPA invalidation. **`until` is the first inactive day** ("dead from", exclusive): the program is active for dates `< until`. This matches IEEPA invalidation (`effective_date >= until` zeroes, `06:754`) but **not** the expiry splitter, which today treats the expiry date as the last *active* day (`query_date > expiry`, `helpers.R:436`) — the engine must converge the two onto one convention. | `effective_date`, heading gates, `IEEPA_INVALIDATION_DATE` |
| `metal` (232-only) | `{type: steel\|aluminum\|copper\|none, content: full\|share}` → drives `metal_share`/`nonmetal_share`. Omit the whole block for `primary_full`/non-metal programs; `content` is required only for content-bearing types. | `deriv_type`, `metal_content`, `s232_annex` |

What disappears into fields: the **heading gate**
(`grepl('9903.94...', ch99_code)`) becomes `active.from`; the **China `if`**
becomes `country_scope`; the **`*_usmca_exception` flags** become
`usmca_treatment`. Each hardcoded thing becomes data.

The four `stacking.class` names (`primary_metal` / `primary_full` / `content_split` /
`additive`) are **normalized labels introduced here, not literal code symbols** — the live
code uses `case_when` branches and `stacking_method` values (`mutual_exclusion` /
`tpc_additive`); don't grep for the class names.

### Baseline semantics the field list must still absorb

The table above is necessary but **not sufficient** for parity. The live
calculator carries behavior the current draft drops; each must land either as an
explicit field or as an explicit pointer into `adjustment_params`, or baseline
will not reproduce:

- **MFN / base-rate layer** — the `base` that `target_total`'s `max(value − base, 0)`
  floors against is itself a first-class layer: deal floors `pmax(deal$rate − base_rate, 0)`
  (`06:1750`), the IEEPA floor (`06:1059`) and Annex-III floor (`06:1991`) all subtract it,
  and MFN exemption shares reduce it (`06:2474`). No spec carries it today. Model it as an
  explicit `mfn` authority (scope = all products, rate = `products$base_rate`), with
  `mfn_exemption_shares` as its `adjustment_params`; otherwise "baseline = empty scenario"
  cannot reproduce the floors.
- **IEEPA phase precedence** — Phase 2 + country-EO entries stack *across* phases; Phase 1
  is **superseded** (rank-2 in `active_rank`, dropped when a later phase exists, `06:863`).
  *Within* a phase the country entry supersedes the group and the highest wins
  (Brazil 10%+40%=50%, Tunisia max(15%,25%)=25%). `06:856-889`.
- **IEEPA universal baseline** — a 10% default applied to every country *not* in the explicit
  entry list and not USMCA-exempt (`06:975-987`), read from `attr(ieepa_rates,'universal_baseline')`.
  This is a default-for-the-complement, structurally distinct from per-country `by_country`;
  model it as an explicit `default_unlisted_rate` on the reciprocal spec.
- **IEEPA `passthrough` rate_type** — a *third* type beyond surcharge/floor (`05:282`, `06:1060`):
  base-rate-only, no additional duty (high-duty goods for floor countries). The surcharge-vs-floor
  switch must be three-way.
- **Country-EO exemptions vs Annex A** — country EOs (Brazil 9903.01.77 …) must
  bypass the universal Annex A or they are wrongly suppressed. `06:801`.
- **Floor-product exemptions** — `floor_exempt_products` zero the reciprocal rate
  for exempt HS8×country-group pairs (`06:1053`; the key set is built at `06:997`).
- **Typed exempt lists** — at least three distinct exempt roles, scoped to different
  authorities, must stay separate: Annex-A/II reciprocal exempt (`ieepa_exempt_products.csv`,
  scope gated by `ieepa_exempt_scope`), the Ch98 fentanyl set (next bullet), and country-EO
  date windows (`06:812`). Each needs a target authority, key granularity, optional date
  window, and whether it zeros the whole rate or only one component.
- **Ch98 fentanyl carve-out** — US Note 2(v)(i): the 9802.00.40/50/60/80 set zeros
  `rate_ieepa_fent`. `06:1230`. This is a *true exemption* (→ `exempt_file`).
- **Fentanyl product carve-outs** — `fentanyl_carveout_products.csv` is a per-product
  **rate-override** list (potash/energy at a *lower* rate), `coalesce(carveout_rate,
  fent_rate, 0)` (`06:1195`) — **not** an exclusion. It belongs under `rate`
  (`product_overrides_file`), never `exclude_file`. Two different file roles —
  rate-override vs scope-exclusion — must stay distinct in the schema.
- **Fentanyl multi-entry supersession** — `max(rate)` per country across multiple general
  fentanyl entries (China 9903.01.20 +10% superseded by 9903.01.24 +20%), plus an
  `entry_type` partition (general vs carveout) joined by HS8×country (`06:1162-1184`).
- **Section 301 active/suspended + Biden/Trump supersession** — 301 Ch99 codes whose
  description says "provision suspended" are dropped (e.g. 9903.88.16 List 4B), and
  `max(s301_rate)` per HS8 supersedes across Trump-era (9903.88) and Biden-era (9903.91)
  lists (`06:2237-2266`). A per-code active/suspended status behaves like an activation window.
- **Wood / lumber 232 program** — softwood vs furniture/cabinet product sets with separate
  deals (UK 10% floor on softwood; EU/JP/KR 15% floor on furniture), `06:1304-1416`,
  `06:1770-1816`. Absent from the 232 examples; it is a real heading program with internal subsets.
- **Date-bounded per-country 232 overrides** — `section_232_country_exemptions` (date-bounded
  TRQ/quota exemptions with `expiry_date`) and `country_surcharges` (permanent Russia 200%
  aluminum, applied via `pmax`, `06:1517`/`06:2047`) are per-country, metal-/annex-scoped, dated
  rate overrides with no current schema home. Give `rate.overrides` an optional `{rate,
  active:{from,until}, applies_to:[programs], metal_types}`, or model each as a tiny synthetic
  program.
- **Annex overrides** (April 2026) — `annex_1a/1b/2/3` rates with a guard that
  preserves separate heading-program rates (EU cars under 9903.94.51) `06:1985`, plus the
  annex sub-mechanisms (`zero_metal_content`, `de_minimis_weight`, `motorcycle_parts`,
  `us_origin_metal` aggregate-share scalings, `06:2003-2092`) → `adjustment_params`.
- **Semiconductor 232 rate blend** — the semi heading rate is
  `heading_232_rate * qualifying_share * (1 − end_use_exemption_share)` (`06:1474`): the
  program scope + 25% default + semi-exclusion precedence are statutory; `qualifying_share`
  (`semi_qualifying_shares.csv`) and `end_use_exemption_share` are `adjustment_params`.
- **`rate_other` catch-all** — `classify_authority()` routes any unmatched footnote-linked
  Ch99 rate to `other` (`rate_schema.R:150`); `rate_other` flows through stacking (additive)
  and the `disable:` vocabulary. The adapter must route it into a generic additive spec.
- **Calculator policy switches** → `adjustment_params` — `ieepa_exempt_scope`
  (`all`/`baseline_only`), `ieepa_duty_free_treatment` (`all`/`nonzero_base_only`, `06:1052`),
  the MFN-exemption `method` (`hs2`), the metal-content `method` (`flat`/`bea`/`cbo`), and the
  global `tpc_additive` stacking mode (`stacking.R:144`) all change baseline output and must be
  pinned (baseline = empty scenario must hold their current values).
- **Auto rebate / US-content shares**, **subdivision-r blends**, **de-minimis** →
  `adjustment_params` (modeling assumptions, not statute). Note subdivision-(r) is *mixed*: its
  product list, country set (EU/JP/KR), and 15% floor are statutory scope; only `certified_share`
  / `fta_exempt_shares` are adjustment knobs (`06:2136-2198`).
- **Section 201** — a live authority (`rate_section_201`, `06:2387`) with a solar product list
  (`s201_solar_products.csv`) and a hardcoded **Canada exemption**
  (`setdiff(countries, CTY_CANADA)`, `06:2401`) — the same hardcode the draft criticizes for 301.
  Promote to a one-program spec (`country_scope: {include: all, exclude: [Canada]}`,
  `stacking.class: additive`) **and** add it to the `disable:` vocabulary
  (`policy_params.yaml:346`), which omits it today.

### Value-configured vs. structure-configured

The distinction that motivates this whole schema: `cty_china = '5700'` being in
config makes the *value* "China" configurable, but the *fact that 301 applies to
exactly `{China}`* is still a hardcoded branch condition — you cannot re-scope
it without editing code. AuthoritySpec promotes every authority from
**value-configured** to **structure-configured**: the set membership itself
(`country %in% spec$country_scope`) is a config list the engine iterates.

Section 232 is already structure-configured for country scope (it parses exempt
lists and country-specific deals from the Ch99 descriptions). 301 and fentanyl
are only value-configured. **The work is promoting them all to the 232 shape.**

### Section 232 program overlap and precedence

A product can match more than one 232 program, so `programs` needs a first-class
resolution rule — the easy "232 on drones" case is easy only because it overlaps
nothing. Baseline behavior to preserve, and the authoring default:

Resolution is a **precedence pipeline**, not a single `max()`:

- **Rate-independent exclusions first.** Semiconductor articles are stripped from the
  auto/copper/wood/MHD lists *regardless of rate* so only the 25% semi rate applies
  (Note 39(a); `06:1383-1394`); and blanket chapter-level steel/aluminum take precedence
  over heading-program membership (`06:1399`).
- **Then highest-rate-wins** among the remaining heading programs (`06:1434`,
  `max(heading_232_rate)`). This is also the default for authored/scenario programs — but a
  rate *cut* cannot win a `max`, so lowering a 232 rate needs the explicit **replace** op
  (see operations).
- **Equal-rate ties need a rule.** `max()` is silent on which program wins at equal rates;
  specify error-or-listed-order so authored overlaps are deterministic.
- **Annex-override guard** — the annex catch-all must not wipe a product's separate
  heading-program rate (`06:1985`, `heading_program_products`).
- **Metadata is combined, not "taken from the winner."** USMCA exemption is OR-combined
  across overlapping headings — `heading_usmca_exempt = any(...)` (`06:1435`) — not read off
  the single max-rate program. `metal` / `stacking.class` resolve onto the canonical
  product-country grid, which carries the active per-type share, `deriv_type`,
  `is_copper_heading`, and `s232_annex` — not a pointer to one "winning program."

## The scenario delta: operations on specs

A synthetic future revision is a small list of operations over the baseline
specs.

A scenario has **two independent dimensions**: `policy` (statutory deltas over the
specs) and `assumptions` (modeling deltas over `adjustment_params`). Either may be
empty. `baseline_mode` selects current-law (keep scheduled expiries) vs
current-policy (cancel them); `base` pins the branch point.

**Recompute scope differs by dimension.** Only `policy` ops carry `effective_from`, so a
policy-only scenario recomputes forward from that date and reuses baseline before it. An
`assumptions` change (USMCA mode, metal-content method) is **not** dated — it is a
*whole-series* rebuild (the scenario overlay is applied to every revision), so it
invalidates the entire series, not just the tip.
Either give assumptions an effective date too, or state this asymmetry explicitly.

```yaml
scenario: drone_232_july2026
description: "232 on drones at 25%, effective 2026-07-31"

policy:
  base: latest                     # or a YYYY-MM-DD pin (effective-date; see "Three borrowings" #2)
  baseline_mode: current_law       # current_law (default) | current_policy
  operations:
    - op: add_program              # the drone case — NEW coverage
      authority: section_232
      effective_from: 2026-07-31
      program:
        id: drones
        product_scope: { prefixes: ['8806'] }
        country_scope: { include: all }
        rate: { default: 0.25 }
        stacking: { class: primary_full }  # 232 owns FULL customs value, IEEPA excluded;
                                           # no metal content (primary_metal would be invalid here)
        usmca_treatment: none

    - op: set_country_scope        # the re-scoping case
      authority: section_301
      program: s301
      country_scope: { include: ['5700','5520'] }   # China + Vietnam (5520)
      effective_from: 2026-07-31

    - op: set_rate                 # the simple rate-bump case
      authority: ieepa_reciprocal
      country: '5520'              # Vietnam
      rate: 0.46
      effective_from: 2026-07-31

assumptions: {}                    # e.g. usmca_utilization, auto_content_share overrides
```

**Operation verbs:** `add_program`, `disable` (authority or program), `set_rate` /
`replace_rate` / `add_rate` / `target_total`, `set_country_scope`, `set_product_scope`
(full replace; or `add_products` / `remove_products`), `set_active`, and `set_field` (a
guarded setter for `stacking.class` / `stacking.exceptions` / `metal` / `usmca_treatment`
of an existing program). Each carries `effective_from`.

**Resolution rules** (must be specified, not implied):
- Operations apply **in listed order**; for the *same target and same date*, later ops win.
  But each op's `effective_from` sets the interval its change takes effect from, so two ops
  on one target at *different* dates produce a **multi-interval timeline**, not last-wins.
- **`set_rate` destination is authority-shape-aware:** for `by_country` authorities (IEEPA
  recip/fentanyl) `set_rate ... country:` writes `rate.by_country[country]`; for `overrides`
  authorities (232 deals, UK) it writes `rate.overrides[country]`. `set_rate` *without*
  `country:` on a `by_country` authority is a **hard error** (require `country:`). `add_rate`
  adjusts; `target_total` sets the all-in floor (writes `rate.target_total`); `replace_rate` overwrites the resolved
  program rate **bypassing highest-rate-wins** (the rate-cut path, decision 8). These write
  orthogonal fields and do not silently cross-write each other.
- **`add_program` with an existing program id is a hard error** (consistent with "never a
  silent no-op"); modify an existing program through the targeted setters above instead.
- `authority` may name an **authority-group alias** (`ieepa` → reciprocal + fentanyl) so one
  op hits both without manual sync. **Country-group aliases** (`eu27`, `swiss`) are a separate
  namespace, valid only in `country_scope` and per-country rate keys (`by_country` /
  `target_total`).
- Unknown authority/program id, unknown census code, or `primary_metal` without a
  `metal.type` → **hard error**, never a silent no-op.

**The timeline splitter must operate on policy boundaries.** A synthetic
revision must build a modified spec set, recompute coverage, assign a synthetic
revision id, and append the forward interval(s) — which the current
`09_daily_series.R` interval-splitting does **not** do.

## Three borrowings from tariff-etrs

ETRs independently arrived at the same scenario shape (a dated timeline + a
delta off a base), which validates this model. Three things from its design are
worth adopting:

1. **Explicit dated-timeline framing.** An ETRs scenario is an ordered list of
   effective-dated states, so one scenario can express *sequential* changes
   (e.g. "S122 expires July 24, *then* pharma 232 layers on Sept 29"). Our
   `operations[].effective_from` already supports this; adopt the framing — a
   scenario *is* a mini revision-timeline appended to the baseline.

2. **A pinnable base, not just `latest`.** ETRs' `historical: '2026-02-24'`
   lets a counterfactual delta off a *specific* base rather than always the tip.
   Support both `base: latest` and `base: <date>` — useful for reproducibility
   and "what if we'd done X back in April." **Semantics of a past pin (effective-date
   cut):** the pipeline records only *effective* dates, never enactment/announcement dates,
   so "suppress revisions *enacted* after the pin" is not computable. Define the pin on
   effective date instead: load the persisted per-revision spec (impl req 1) at-or-before
   the pin, which by construction keeps every change *already scheduled as of then* (s122
   sunset, Annex III) and excludes revisions whose effective date is later. Deltas layer on
   top; they do not overwrite scheduled changes unless an op explicitly targets one. (The
   unrecoverable edge: a change *announced* before the pin but *effective* after it cannot be
   told apart from one announced after — accept this, or add an enactment-date column to the
   revision data.) `baseline_mode: current_policy` is the canned scenario that cancels the
   **IEEPA/s122 sunsets** (`set_active until: null`); note it does *not* freeze the other
   scheduled changes that still bend the path (annex restructuring `06:1906`, annex_3 sunset
   `06:2096`), which are not expiries. So current-law and current-policy share one engine —
   current-law is the empty scenario, current-policy is a standard named one.

3. **The statutory / adjustment-parameter boundary.** ETRs keeps statutory
   rates (the dense CSV from the tracker) separate from *adjustment* parameters
   (metal-content method, `us_metal_origin_share`, `de_minimis_weight_share`,
   USMCA shares) in `other_params.yaml`, overlaid by simple shallow-merge. Keep
   that boundary: AuthoritySpec owns statutory structure; a separate
   `adjustment_params` object owns ETR adjustment knobs. Coarse shallow-merge is
   fine for scalar knobs — reserve the richer operation vocabulary for statutory
   structure. **Caveat:** shallow-merge is adequate only for *true scalars*. Several
   "adjustment" knobs are not scalar — `usmca_shares` is a `(mode, year, month)` selector
   that resolves to monthly-file aggregation (`data_loaders.R:109-260`), and `auto_rebate`
   is a fail-closed block of three required keys (`06:1660`) — so `adjustment_params` needs
   its own field reference and merge rules (see below), not just a scalar overlay.

### Why this is complementary to ETRs, not redundant

ETRs has *already migrated off* structured statutory config onto the tracker's
dense `statutory_rates.csv.gz`; its structured per-authority YAMLs
(`config/archive/*/s232.yaml`, `ieepa_reciprocal.yaml`) are legacy, and are
essentially a subset of `AuthoritySpec`. Because ETRs now holds *flat* rates, its
reforms can only tweak adjustment parameters — it **cannot** add coverage or
re-scope an authority. ETRs' architecture already assumes statutory deltas come
from upstream. `AuthoritySpec` is exactly that missing upstream half.

| | Tracker (`AuthoritySpec`) | ETRs (reform overlays) |
|---|---|---|
| Owns | statutory structure: scope, rates, coverage, stacking | adjustment params: metal content, exemption shares, USMCA |
| "232 on drones" / "301 → Vietnam"? | ✅ structured scope, upstream | ❌ flat rates, downstream |

### The `adjustment_params` dimension (field reference)

`adjustment_params` is a real contract, not a bag of scalars — enumerate it the way the
spec enumerates statutory fields:

| Knob | Shape | Where it lives today |
|---|---|---|
| `usmca_shares` | `(mode, year, month)` selector → resolves to a file / monthly aggregation at calc time; modes `none` / `annual` / `monthly` / `fixed_month` / `hybrid_rolling` | `data_loaders.R:109-260`; `06:2536-2646` |
| `auto_rebate` | **fail-closed** block `{rebate_rate, us_assembly_share, us_auto_content_share}` (missing key → error) | `06:1660-1672` |
| `metal_content` | `method` ∈ `flat`/`bea`/`cbo` + per-type share file (`bea` enables steel/aluminum/copper/other shares) | `06:471-508`, `metal_content_shares_bea_hs10.csv` |
| `subdivision_r` | `certified_share` + `fta_exempt_shares` — **only the shares**; the product list, EU/JP/KR set, and 15% floor are statutory | `06:2136-2198` |
| `mfn_exemption` | `method` ∈ `hs2`/off + HS2×country share file → reduces `base_rate` | `06:842`, `06:2456-2474` |
| `ieepa_exempt_scope` / `ieepa_duty_free_treatment` | enum switches that change which products get reciprocal | `06:773/782/1052` |
| `tpc_additive` | global stacking mode (all authorities additive; sensitivity) | `stacking.R:144` |
| `de_minimis` | weight-share knob | (assumptions) |

Merge rule: scalar knobs shallow-merge; the file-/mode-backed knobs (`usmca_shares`,
`metal_content`, `mfn_exemption`) resolve through their loader and must be **pinned in the
persisted per-revision state** so a `base:<date>` reload reproduces them.

**Cross-dimension coupling.** §232 heading programs carry their product scope, activation,
rate, USMCA treatment, and adjustment settings together. The calculator derives the auto,
MHD, metal, semiconductor, and pharmaceutical sets from those programs on the canonical
grid; it does not maintain an alternate program table.

## Data flow under the new model

```
JSON archives ──parse(03/04/05)──▶ [AuthoritySpec × authorities]  ◀── baseline = specs as-is
                                            │                          scenario = specs + operations
                                            ▼
                  calculate_rates_for_revision(specs, products, countries)
                                            │   (one apply path; stacking.class picks the math)
                                            ▼
                                       rate panel ──▶ stacking ──▶ daily / ETR
```

`calculate_rates_for_revision()` stops taking `ieepa_rates`, `s232_rates`,
`fentanyl_rates` as separate ad-hoc args and takes **one list of
`AuthoritySpec`**. The parsers' job becomes "normalize JSON into specs." The
scenario layer's job becomes "apply operations to specs." Both hand the
calculator the identical shape.

## Output layout: vintages, `actual`, and named scenarios

Two independent version axes — keep them separate:

- **Vintage** = *when the model was built* (provenance): a dated, immutable directory with a
  `latest` symlink to the newest. Unchanged by this migration.
- **`base:` pin** = a counterfactual's *branch point on the policy timeline* (an effective-date
  cut into the content, decision 6) — a field **inside** a scenario, **not** a directory level.

Within a vintage every series has the **identical schema** (the migration is parity-gated on
exactly this), so a consumer reads `actual` and any scenario the same way:

```
<shared root>/Tariff-Rate-Tracker/
  <vintage = YYYY-MM-DD>/                  # immutable build snapshot
    actual/                                # current-law series = output of the empty-scenario run
      timeseries/rate_timeseries.parquet   #   (realized past + scheduled future, through the horizon)
      daily/daily_*.csv
      metadata.rds
    scenarios/
      <scenario-name>/                     # name supplied at run time (or a named scenario file)
        timeseries/rate_timeseries.parquet
        daily/daily_*.csv
        manifest.json                      # base:, baseline_mode, operations, adjustment_params, parent vintage
    manifest.json
  latest -> <newest vintage>               # atomic symlink
```

- **`actual`** (deliberately *not* "baseline") is the current-law time path — realized history
  **plus** scheduled future through `series_horizon`. It is literally the output of the
  empty-scenario run ("baseline = empty scenario"); we publish it under `actual/` because
  "baseline" is overloaded across Budget Lab models (it can mean *pre-2025 policy*). The doc's
  internal "baseline" still means the empty-scenario computation; `actual/` is its published
  series.
- **`scenarios/<name>/`** — each counterfactual is a first-class, vintage-scoped series with a
  **run-time name** from the scenario registry. Its `manifest.json` records
  the full recipe (`base:`, `baseline_mode`, the operations, the `adjustment_params` overrides,
  and the parent vintage) so the run is reproducible.

A downstream consumer points at exactly one of:

```
…/latest/actual/…                       # current-law, newest build
…/latest/scenarios/<name>/…             # a named counterfactual, newest build
…/<pinned-vintage>/scenarios/<name>/…   # fully reproducible (specific build × specific scenario)
```

This is a **breaking path change** from today's layout (current-law at the vintage root;
scenarios as suffixed files in `alternative/`); migrate `publish_internal.R` / `publish_git.R`
and every consumer in lockstep (migration step 5 below).

## Implementation requirements surfaced in review

Three things the schema implies but the current code does not yet support:

1. **Per-revision spec persistence (for `base: <date>`).** `policy_params.yaml` is
   *current-only* — it is not versioned as "what we knew on 2026-02-24" (IEEPA
   invalidation date, s122 expiry, Swiss/Annex settings, horizon all live in the
   single current file). A past pin would otherwise leak *today's* future knowledge
   into a historical baseline. Requirement: each baseline revision **saves its
   normalized `AuthoritySpec` + `adjustment_params`**; a pinned `base:` loads the
   saved state at-or-before the pin (on **effective date**, per decision 6); a scheduled
   future event continues only if it was already encoded in that saved state. The persisted
   artifact must hold the **resolved, date-fixed** `policy_params` slice (IEEPA invalidation
   date, s122/Swiss windows, annex settings, horizon) — not a pointer to the current file —
   and record `use_policy_dates`, since `policy_effective_date` silently overrides
   `effective_date` under the default build (`revisions.R:119`), so a pinned reload must
   reproduce the same date axis. (Retroactive corrections — rev_5/6/7 "retroactive to April
   6" — mean the spec must also record whether it captured the as-published or as-corrected
   JSON.) Without this, "past base" is reproducible only by `git checkout`, not by scenario
   config.

2. **One canonical product-country grid.** `build_rate_grid()` creates the full
   product-country universe once. Authorities mutate their own rate and metadata columns;
   none may add rows or create an intermediate per-program panel. The final invariant checks
   the exact Cartesian row count and unique `(hts10, country)` key before stacking.

   **Define the output contract.** Earlier sections promise the RATE_SCHEMA panel is
   *preserved*, while this collapses to `rate_*` only after stacking — resolve the tension by
   stating which artifact each consumer reads. Today `09` re-derives net authority
   contributions from the snapshot's `rate_*` columns **plus preserved extras** (`09:220`,
   `compute_net_authority_contributions`). Decide whether the program table is internal-only,
   persisted as snapshot *extras* (formalizing today's per-type-share extras), or *replaces*
   that downstream decomposition — and say which.

3. **A unified timeline splitter.** The synthetic-revision builder must collect **all**
   schedule boundaries into one splitter — `active.from` / `active.until`, scenario
   `effective_from`, the horizon, and **every `effective_date`-keyed gate**, not just the two
   post-panel expiries (s122/Swiss) in `collect_expiry_adjustments`. The calculator-internal
   gates are easy to miss because they are not "expiries": annex activation (`06:1906`),
   annex_3 sunset (`06:2096`), IEEPA invalidation (`06:754`), and Ch99 `effective_date_offset`
   activations (`filter_active_ch99`). Today these reach the timeline through two separate
   mechanisms (`filter_active_ch99` + `get_expiry_split_points`) that do **not** cover
   mid-interval Ch99 activations; the unified splitter replaces both.

## Migration plan (incremental, not a rewrite)

Each step is independently shippable and leaves the panel output **within numeric
tolerance** (refactors reorder float ops, so byte-identity is the wrong bar).

0. **Parity harness first — build it, don't "extend."** Neither a baseline golden, a
   per-authority golden, nor a tolerance comparator exists today, and
   `scripts/submit_alt_equivalence.sh` needs a tolerance-aware comparison over the
   registered scenario set. So:
   author a tolerance comparator (specify ε **per column class** — rates vs shares vs
   weighted ETR — absolute or relative, plus near-zero handling), capture a **baseline +
   per-authority golden** from a clean build, and **drive the variant list from
   `list_scenarios()`** so it cannot drift again. This is the safety net the rest
   of the plan leans on.

   The migration also has real **API blast radius**: replacing `ieepa_rates` /
   `s232_rates` / `fentanyl_rates` with one spec list touches both build paths
   (`00_build_timeseries.R:254`, `09_daily_series.R`). Make the **adapter + signature change**
   its own parity-gated step (between 0 and 1), with a transitional path that accepts both the
   old args and a new `specs` arg, before any generic loop.

1. **Normalize the inputs — in two commits.** *(1a)* Introduce the adapter and re-plumb the
   calc to read fields off the spec *while still re-extracting internally* — a pure shape
   change, easiest to prove parity, no behavior moves. *(1b, separately)* Make the spec
   **authoritative**: today `calculate_rates_for_revision()` always re-derives `s232_rates`
   from the date-gated `ch99_data` (`06:724-726`, `06:1276-1278`), discarding the passed-in
   argument, **and** `calculate_rates_fast()` seeds *all seven* authority columns directly
   from Ch99 footnote refs (`classify_authority` → pivot, `06:50-230`) before the authority
   blocks run. Both the re-extraction *and* the footnote-seeding path must be gated/converted
   so a synthetic spec actually drives the panel's first write — a behavior-bearing move,
   parity-gated, not a no-op. Then move program activation into the structure (`active.from`)
   instead of the raw-Ch99 grep at `06:1313`. **Note:** IEEPA invalidation is today a
   whole-revision kill switch at two sites (`06:754`, `06:1266`) plus a grid densification;
   mapping it to per-authority `active.until` needs an explicit parity case and lockstep
   conversion of both sites. (These steps preserve the calculator's internal step sequence —
   the multi-step calc, ~15 numbered steps per the file header — only the *inputs* change.)

2. **Un-hardcode scope** for 301 / fentanyl. The authoritative coverage gate — the one that
   decides whether a 301 rate exists at all — is in the calculator, **not** `stacking.R`:
   `06:2275-2304` scopes `rate_301` to China (`if_else(country == CTY_CHINA, pmax(rate_301,
   blanket_301), rate_301)`, and forces new rows to `CTY_CHINA`). Replace it with
   `country %in% spec$country_scope` there **first**, then also un-hardcode the downstream
   `country == cty_china` branches in `src/model/stacking.R` (`apply_stacking_rules` `:161/166`,
   `compute_net_authority_contributions` net_301 `:239`). Editing only `stacking.R` would
   leave 301 scoped to China and still pass a byte-identical baseline — a silent miss.
   Small, high-value, unlocks re-scoping scenarios.

3. **Apply common specs to the canonical grid.** The adapter resolves parser outputs into
   explicit programs; the calculator reads those programs and the shared stacker consumes
   the resulting wide columns. There is no second stacking engine or resolved-program table.

4. **Collapse steps opportunistically.** Once authorities are uniform specs, the
   per-authority step blocks can merge into a generic "apply each spec" loop.
   Optional polish, not a prerequisite.

5. **Restructure published output so scenarios are first-class on disk** (depends on 1–3,
   independent of 4). Adopt the `actual/` + `scenarios/<name>/` layout (see "Output layout"
   above): move the current-law series from the vintage root into `actual/`, promote scenarios
   from flat `alternative/<kind>_<variant>.csv` suffixes to named `scenarios/<name>/`
   subdirectories each carrying a `manifest.json` recipe, and migrate `publish_internal.R` /
   `publish_git.R` plus every downstream consumer in lockstep — a **breaking path change**, so
   land it as one coordinated cut.

USMCA is the one authority left as-is: its `{Canada, Mexico}` scope is
definitional, not a policy choice.

### End-state (future, not part of the initial migration)

Once steps 1–4 hold parity and per-revision spec persistence is in place, the
**adapter and the bespoke `param-object-1` structs can be removed entirely**: the
parser emits `AuthoritySpec` directly ("normalize JSON into specs"). This is a *fold*,
not a deletion — the extraction logic moves into the parser rather than disappearing,
so the performance win is modest (the saved cost is the reshape, not the parsing). The
real wins are a single source of truth and removing the redundant re-extraction that
`00_build_timeseries.R:233`, `09_daily_series.R:1156`, and `06` (internally) each do
independently today. Why it is a *later* step, not the first one:

- It must follow parity lock-in — emitting specs directly changes parsing, shape, and
  the calculator interface at once, which is unbisectable if parity breaks.
- All five build/read sites (`00`, `09`, `06`, `generate_etrs_config.R`) must migrate
  together, consolidating the three independent pre-extractions into one. **This is not a
  pure fold:** the sites diverge today — `generate_etrs_config.R:229` extracts 232 from
  *unfiltered* `ch99` and its heading-gate list lacks the `semiconductors` entry that
  `06:1325` has — so reconcile (or fix) those before consolidating, and add the ETR-config
  output to the parity gate.
- The spec is assembled from JSON **plus** `policy_params.yaml`, so "parser emits spec"
  is really "parser + config-merge emits spec"; some `param-object-1` fields (`has_232`,
  `auto_has_deals`) are gating scratch and need triage, not a 1:1 copy.
- It composes with per-revision persistence: the persisted spec then becomes the
  canonical per-revision artifact, and `param-object-1` has no remaining consumer.

## Open questions

- **Rate representation for product-tiered authorities** (301 at 7.5% / 25%):
  carried by the `list_file` (`by_product_tier`), or split into multiple
  programs? The list-file approach matches the current `s301_product_lists.csv`.
  Note `add_program` for a file-backed authority has no inline tier path today —
  adding *new* 301 product coverage in a scenario needs a file or an inline tier list.
- **Effective dates beyond the horizon**: scenarios effective in 2027 require
  extending `series_horizon` (currently `2026-12-31`). This also interacts with weighting —
  import weights are fixed at 2024 Census flows, so far-forward intervals carry stale weights;
  decide whether 2027 scenarios error, clamp, or re-weight.

**Deferred — operational lifecycle** (out of scope for this revision; recorded so they are
not lost):

- **New-coverage weight provisioning.** `add_program` over genuinely new products only moves
  revenue if those `hts10 × country` pairs exist in the 2024 Census import weights — the ETR
  weighting `inner_join`s on them (`08:389`), so thin/absent flows are silently zero-weighted.
  The drone (`8806`) flagship example needs this checked.
- **Scenario-correctness validation.** Parity (step 0) covers baseline only. There is no
  golden/fixture for a counterfactual, no "this op changed exactly these rows and nothing
  else" assertion, no regression harness for the verb vocabulary.
- **Backward compatibility:** none. Scenario inputs use the config-overlay
  registry; retired formats are not translated or dual-supported.
- **Multi-scenario composition.** The on-disk layout is now settled (see "Output layout":
  `scenarios/<name>/`); what remains is how the `policy × assumptions × baseline_mode × base`
  cross-product is *enumerated and named* (one scenario name per combination, or nested?).
- **Results / reporting.** A policy user needs the revenue/ETR-delta decomposition, not a raw
  `hts10 × country` rate diff — specify the scenario output.
- **Recompute cost.** A synthetic revision recomputed forward is not free; the existing alt
  rebuilds budget ~85 min / 192 GB per batch (`submit_alt_equivalence.sh`). Bound it.
- **Scenario-file versioning** (`schema_version`) and migration of old scenario files as the
  verb vocabulary evolves.
- **Authoring UX.** A `--validate-scenario` dry-run (resolve scopes/codes/programs, report
  what *would* change before a multi-hour recompute) and a YAML schema for editor validation;
  a successor to `docs/scenarios.md`.
- **Synthetic-revision id.** Must not collide with or missort against real `rev_N` ids —
  `snapshot_<rev>.rds`, `delta_*.rds`, `compare_scenarios`, and the changelog all key on it.

_Resolved during review:_ `adjustment_params` is a **separate scenario dimension**
(decision 3), not folded into the spec. Identifiers are **Census codes** (decision 5).
Parity is **numeric tolerance** (decision 4). Baseline is **current-law by default**
with current-policy as a canned scenario (decision 6).
