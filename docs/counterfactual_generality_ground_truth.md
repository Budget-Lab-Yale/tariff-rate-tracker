# Ground truth: what's config vs hardcoded, and what it takes to add an arbitrary new tariff

**Status:** Diagnostic. No code changed. Written 2026-06-04 after John asked for a verified
ground-truth map (not memory, not vibes) of how configurable the tariff model actually is, prompted
by discovering that a new Section-232-style tariff (pharma) can't be added with correct stacking.

**How this was built:** direct reads of `src/model/stacking.R`, `src/model/resolved_programs.R`,
`src/pipeline/06_calculate_rates.R`, `src/pipeline/05_parse_policy_params.R`, `src/scenario_ops.R`,
`src/new_coverage.R`, `src/model/rate_schema.R`, `config/policy_params.yaml`, plus two code-review
subagents. Every claim below is grounded in code; line numbers drift, so re-grep before relying on
an exact line.

**The headline:** nothing shipped is wrong — the baseline reproduces real-world stacking exactly
(that's why it's byte-identical to golden). This is a **missing capability**, not a correctness
bug. The AuthoritySpec refactor built the container and generalized the stacking *arithmetic*, but
left two wires disconnected: (1) the stacking *class* is still a hardcoded table, not read from the
spec; (2) "displacement" is hardwired to metal-232 and was never generalized. New coverage can only
be added as a plain additive surcharge.

---

## Part 1 — The data model, as it actually is

### 1.1 Seven fixed rate columns

`RATE_SCHEMA` (`src/model/rate_schema.R:12-20`) is a fixed vector. The additional-tariff columns are
exactly seven, one per known authority:

```
rate_232, rate_301, rate_ieepa_recip, rate_ieepa_fent, rate_s122, rate_section_201, rate_other
```

Plus `base_rate`, `total_additional`, `total_rate`, `metal_share`, identifiers, and the interval
columns. The schema is "frozen" by convention but technically extensible (add to the vector +
`enforce_rate_schema` defaults, ~10 lines) — see §4.4. Every authority maps to exactly one of these
columns via `authority_columns:` in `policy_params.yaml` (`section_232 → rate_232`, etc.).

### 1.2 Three stacking classes — but the math has only TWO behaviors

`default_stacking_policy()` (`src/model/stacking.R:141-152`) assigns each column a class:

| Column | Class |
|---|---|
| `rate_232` | `primary` |
| `rate_ieepa_recip` | `content_split` |
| `rate_ieepa_fent` | `content_split` (+ `additive_countries = China`) |
| `rate_301` | `additive` |
| `rate_s122` | `content_split` |
| `rate_section_201` | `additive` |
| `rate_other` | `additive` |

But look at what the contribution math actually does (`src/model/stacking.R:160-175`):

```r
if (identical(p$class, 'content_split')) {
  add_ctry <- p$additive_countries %||% character(0)
  split_active <- df$rate_232 > 0 & !(df$country %in% add_ctry)
  df[[contrib]] <- df[[col]] * if_else(split_active, df$nonmetal_share, 1)
} else {
  df[[contrib]] <- df[[col]]                 # primary + additive both: full rate
}
```

So there are really **two** behaviors: `content_split` → *scaled by `nonmetal_share` when a 232 is
present*; everything else → *full rate*. `primary` and `additive` are arithmetically identical at
this step (both contribute their full rate); `primary` is special only because it is the thing that
*sets up* `nonmetal_share` for the others.

### 1.3 "Displacement" exists only as metal-232

`nonmetal_share` (`src/model/stacking.R:73-115`) is computed **entirely** from metal content:

```r
.active_type_share = case_when(
  rate_232 > 0 & .ch2 %in% c('72','73')              ~ steel_share,
  rate_232 > 0 & .ch2 == '76'                         ~ aluminum_share,
  rate_232 > 0 & is_copper_heading                    ~ copper_share,
  rate_232 > 0 & deriv_type == 'steel'                ~ steel_share,
  rate_232 > 0 & deriv_type == 'aluminum'             ~ aluminum_share,
  rate_232 > 0 & metal_share < 1.0                    ~ aluminum_share,  # fallback
  TRUE ~ 0),
nonmetal_share = if_else(rate_232 > 0 & .active_type_share > 0, 1 - .active_type_share, 0)
```

There is **no general notion of "authority A displaces authority B."** The only displacer is
metal-232, the displacement amount is the metal content, and the displaced set is whatever is class
`content_split`. The whole thing is gated on `rate_232 > 0`. (A non-metal 232 like autos is handled
by treating it as `metal_share = 1` / annex → `nonmetal_share = 0`, i.e. *full* displacement of the
reciprocal — see `src/model/stacking.R:107-112`.)

### 1.4 The stacking class is hardcoded; the spec's class field is inert

`default_stacking_policy()` is a plain R function. **Every** stacking call site uses it as the
default and none derives the policy from a spec:
- `06:2827` `resolve_and_collapse(rates, default_stacking_policy(CTY_CHINA))`
- `06:2829` / `stacking.R:216` `apply_stacking_rules(... stacking_policy %||% default_stacking_policy(cty_china))`
- `09` (six sites), `08`, `helpers.R:456`, `export_for_etrs.R`, `compare_etrs.R` — all the default.

`apply_stacking_rules` *accepts* a `stacking_policy` argument (`stacking.R:178/216`), but **no caller
passes one.** The `AuthoritySpec` datatype carries a `stacking = list(class = ...)` field and the
adapter populates it, but the only code that reads a stacking class is `resolved_programs.R:73`,
which builds it from `map_chr(policy, 'class')` — i.e. from `default_stacking_policy`, **not from the
spec.** The spec's stacking field is **populated but never read.** This is exactly the Phase-3a
caveat recorded in the migration notes ("spec→policy wiring NOT done").

There is also **no `set_stacking` operation** — the ops verbs are `set_country_scope`, `set_active`,
`disable`, `set_rate`, `set_exempt`, `add_program` (`scenario_ops.R:109-114`). Nothing can change how
an authority stacks.

### 1.5 The calculator is ~75% generic, ~25% bespoke-per-authority

`calculate_rates_for_revision()` (`06`) is a ~9-step pipeline (`06:17-32`). Most of it is generic
(footnote extraction → `calculate_rates_fast`, chapter/heading matching from config, dense-grid,
schema). But ~600 lines are irreducibly authority-specific hardcodes:

| Bespoke block | Lines (approx) | What it hardcodes |
|---|---|---|
| IEEPA reciprocal | `06:860-1244` (~110 hard) | CA/MX exemption, floor-country group (EU/JP/KR/CH), country-EO surcharges |
| IEEPA fentanyl | `06:1246-1352` (~30) | Country rates by Ch99 range: MX +25%, CA +35%, CN +10%; carve-outs |
| 232 deals | `06:1787-1917` (~130) | EU/JP/KR auto+furniture floors, UK surcharges |
| 232 annex (Apr 2026) | `06:1992-2304` (~300) | Annex tier mapping, Russia 200%, EU/JP/KR subdivision-(r) |
| 301 | `06:2306-2438` (~50) | China scope (spec-overridable), Trump-vs-Biden rate `max()` |
| 201 | `06:2506-2550` (~15) | Canada exclusion (spec-overridable) |
| USMCA | `06:2647-2802` (~160) | CA/MX scope + which authorities scale and how |

These handle the messy real-world specifics of the *existing* authorities (deals, phases,
carve-outs). A *clean* new tariff doesn't need most of them — but a new tariff that wants
deal-rates, phase-ins, or USMCA scaling would need its own bespoke code or new config.

---

## Part 2 — Per-authority ground truth

For each authority: where its **rate**, **product scope**, and **country scope** come from —
**config** (`policy_params.yaml` / a `resources/*.csv`), **parsed** (from HTS Ch99 JSON),
**hardcoded** (in R), or **spec** (carried on the AuthoritySpec, mutable by a scenario op).

| Authority | Rate | Product scope | Country scope | Stacking class | USMCA-scaled? |
|---|---|---|---|---|---|
| **section_232** | parsed (steel/alum blanket) + config (copper/autos/wood/semi headings) + parsed (UK etc. deals) | hardcoded chapters 72/73/76 + config heading prefixes/CSVs | hardcoded universal + config exemptions + parsed deals + **spec-mutable** | `primary` | yes (autos/MHD only, by auto-content share) |
| **section_301** | **config** (`section_301_rates` table) | config (`s301_product_lists.csv`) | **hardcoded China** + **spec-mutable** (P2e) | `additive` | no |
| **ieepa_reciprocal** | parsed (Ch99 phases) + config (Swiss floor) | all-products blanket − config exempt CSVs | parsed + **hardcoded CA/MX exclude** + spec (invalidation date) | `content_split` | yes |
| **ieepa_fentanyl** | parsed, **by Ch99 country range** | parsed + carve-out CSV | **hardcoded MX/CA/CN by code range** (no spec) | `content_split` (China→additive) | yes |
| **section_122** | parsed (9903.03.01) + **spec-mutable** | all − config exempt CSV (Annex II) | **hardcoded all** (date-gated) | `content_split` | yes |
| **section_201** | **config only** (0.145) | config (`s201_solar_products.csv`) | **hardcoded all-except-Canada** + **spec-mutable** (P2e) | `additive` | no |
| **other** | parsed (Ch99 fallback) + **spec-mutable** (P8 new-coverage flat rate) | parsed + spec | parsed + spec | `additive` | no |

Key takeaways from the table:
- **Stacking class is hardcoded for all seven** (Part 1.4) regardless of what the spec says.
- **Country scope is spec-mutable for only 301 / 201** (and 232's exemptions, and the recip
  invalidation date). **Fentanyl's CA/MX/CN scope is hardcoded by Ch99 code range** with no spec or
  config override — the hardest country-scope case. **s122 is "all countries," hardcoded.**
- **USMCA treatment is hardcoded per authority** (which ones scale, and by what); only the
  *magnitude* (shares) is config. A new authority gets no USMCA scaling unless code is added.

---

## Part 3 — What the refactor delivered vs. what was designed

The AuthoritySpec design (`docs/authority_spec.md`, `MEMORY` consolidation notes) explicitly called
for **every authority to be structure-configured, including stacking class and country scope**, so
that "baseline = empty scenario" and any authority could be re-scoped/added as data. Here's the
honest delta:

**Delivered:**
- ✅ The `AuthoritySpec` datatype, constructors, validation (`src/model/authority_spec.R`).
- ✅ Rates/product-scope embedded in the spec and mutable by ops (`set_rate`, `set_exempt`,
  `set_country_scope`, `disable`, `set_active`) — for the authorities wired in.
- ✅ Country scope promoted to data for **301 and 201** (the re-scope capability).
- ✅ The stacking **arithmetic** generalized into a class-driven policy + the **resolved-program
  table** substrate (`src/model/resolved_programs.R`) that *would* stack any class correctly if told.
- ✅ Additive new coverage via `add_program` → `rate_other` (`src/new_coverage.R`).

**NOT delivered (the two missing wires + the on-ramp):**
- ❌ **Wire 1:** the stacking *class* is still the hardcoded `default_stacking_policy()` table; the
  spec's `stacking.class` field is populated but **never read** (§1.4). No `set_stacking` verb.
- ❌ **Wire 2:** "displacement" was never generalized beyond metal-232 (§1.3). There is no way to
  express "this new tariff displaces the reciprocal."
- ❌ **On-ramp:** new coverage can only be **additive** (`rate_other`). You cannot introduce a new
  tariff of the `primary` or `content_split` type.
- ❌ Country scope still hardcoded for **fentanyl** (CA/MX/CN) and **s122** (all).

**Why it stalled here (not an accusation — the reason is structural):** the migration's gate was
**byte-identical baseline**. The hardcoded `default_stacking_policy()` + `compute_nonmetal_share`
reproduce the historical `case_when` exactly, so generalizing the *math* could be proven identical,
but flipping the *class source* to the spec or generalizing displacement **changes the wiring in
ways the byte-identity gate alone can't bless cheaply**, so each was deferred. The capability exists
in the arithmetic; it has no on-ramp.

---

## Part 4 — Scoping the fix

Goal (John's words): *"add an arbitrary tariff correctly with perfect precision of any of the
existing types."* That's three tiers of ambition, with very different costs.

### Tier A — a new ADDITIVE tariff (works today)
A flat surcharge that stacks on top of everything (no displacement, no USMCA, fixed scope):
`add_program` → `rate_other`. **Done.** Covers genuinely-additive new duties.

### Tier B — a new tariff that DISPLACES the reciprocal (the pharma-232 case)
The realistic near-term need. Requires Wire 1 + a displacement path. Two routes:

- **B-cheap — ride the 232 column (the autos pattern).** Treat the new tariff as another 232
  sub-program with `metal_share = 1` (so `nonmetal_share = 0` → reciprocal fully displaced on those
  goods). Reuses all existing machinery; gets the **numbers** right for full displacement.
  *Costs:* (1) the new tariff's rate lands in `rate_232`, muddying provenance (pharma mixed into
  "232 metal"); (2) `compute_nonmetal_share` must resolve the new products to `nonmetal_share = 0`
  (a "full-value 232" flag or annex-style entry, `stacking.R:107-112`); (3) only does **full**
  displacement, not partial. Effort: **small-to-medium**, mostly in `add_program`/seeder + a flag in
  `compute_nonmetal_share`.
- **B-general — see Tier C.** If partial displacement or clean provenance matters, you need the
  general model.

### Tier C — arbitrary tariff of any existing type, perfect precision (the full ask)
Three pieces of work, increasing in difficulty:

**Wire 1 — make the stacking class come from the spec (small–medium).**
- Build the stacking policy *from the spec set* (read `spec$stacking$class` + `authority_columns`
  mapping) instead of calling `default_stacking_policy()`. `apply_stacking_rules` already takes a
  `stacking_policy` arg — thread a spec-derived one through.
- **The real cost is plumbing, not logic:** stacking re-runs **downstream** in `09`/`08` on the
  panel *without* the spec (Phase-3a caveat). So the policy must **travel with the panel** (a sidecar
  column/attribute or a per-vintage policy file) or be rebuilt identically downstream. Get this
  wrong and a scenario that changes a class silently won't reach the daily/published series.
- **Parity:** when specs are baseline, the spec-derived policy must equal `default_stacking_policy()`
  exactly → byte-identical gate still applies. Add a `set_stacking` op.

**Wire 2 — generalize "displacement" beyond metal-232 (the genuinely hard part).**
- Today: `content_split` is gated on `rate_232 > 0` and scaled by a metal-specific `nonmetal_share`
  (§1.3). To support an arbitrary displacing authority you need a general relation: *"authority P is
  primary on these pairs and displaces authorities {Q…} by share s(pair)."*
- The natural substrate is the **resolved-program table** (`src/model/resolved_programs.R`) — it already
  carries one row per (pair, authority) with class + metal_type + nonmetal_share + precedence. But
  its split logic still keys on `.has_232` (`resolved_programs.R:99`). Generalizing means replacing
  "`.has_232`" with "a primary displacer is present on this pair" and replacing the metal-specific
  `nonmetal_share` with a per-(pair, primary) **displaced-share** that the metal computation becomes
  one special case of.
- **Why it's hard:** the metal-content split is genuinely complex (per-metal-type shares, derivatives,
  the April-2026 annex full-value override). A general model has to subsume all of that as one case
  **and** stay byte-identical on baseline. This is a stacking-core redesign, not a wire. It is also
  the part most likely to surface "we never actually decided how X displaces Y" policy questions.
- **Performance note:** the resolved (long) table is ~7× the panel and only runs at resolution
  (once/revision), behind `TARIFF_RESOLVED_STACKING` (default off). The fast wide path
  (`apply_stacking_rules`) is what production/daily use. A general displacement model has to live in
  *both* or the wide path has to be regenerated from the policy — another reason Wire 1's
  "policy travels with the panel" matters.

**On-ramp — let new coverage target any class, not just `rate_other` (medium).**
- `add_program` + `apply_new_coverage_programs` write only to `rate_other` (`new_coverage.R:97-103`).
  Generalize so a new program declares its target column + class (+ displaced set, once Wire 2
  exists) and the seeder writes there. Needs the schema slot (§4.4) if it's a genuinely new column.

### 4.4 The fixed-column question
For "any of the **existing** types" you ride an existing column, so the frozen schema is *not* a
wall — but the metal-232 column carries baked-in metal logic, so a non-metal "232-type" tariff
either rides it as a special case (Tier B-cheap) or needs Wire 2. For a genuinely **novel** authority
(new behavior, new column) you add to `RATE_SCHEMA` (~10 lines) + `classify_authority` + the stacking
policy + USMCA treatment — each new column is a few small wirings, not a redesign.

### 4.5 Effort / risk summary

| Piece | Effort | Risk | Unlocks |
|---|---|---|---|
| Tier A (additive new coverage) | done | — | flat new surcharges |
| Wire 1 (class from spec + sidecar) | small–medium | medium (downstream plumbing; parity) | per-authority class as data; `set_stacking` |
| Tier B-cheap (ride 232 col, full displacement) | small–medium | low–medium | pharma-style full-displacement new tariffs (numbers right, provenance muddy) |
| On-ramp (new coverage → any class) | medium | medium | new tariffs of `content_split`/`primary` type |
| Wire 2 (general displacement) | **large** | **high** (stacking-core redesign; surfaces policy gaps; must stay byte-identical) | partial displacement, clean provenance, true "arbitrary type" |
| Fentanyl/s122 country scope → spec | small each | low–medium | re-scoping those authorities |

---

## Part 5 — Recommendation

1. **Don't panic-rewrite.** The baseline is correct and gated. The generalized arithmetic and the
   resolved-program substrate are real assets — this is finishing wiring, not starting over.
2. **Decide the actual target.** "Perfect precision for any type" = Tier C = a stacking-core
   redesign (Wire 2). If the real near-term need is "add a new tariff that behaves like a 232"
   (pharma), **Tier B-cheap + Wire 1** likely gets correct numbers far sooner, accepting muddier
   provenance. Worth confirming which John actually needs before sizing Wire 2.
3. **Sequence:** Wire 1 first (it's a prerequisite for everything and is mostly plumbing + a parity
   gate). Then the on-ramp. Then Tier B-cheap for the immediate pharma need. Treat Wire 2 (general
   displacement) as its own scoped project, because it will surface real policy-modeling questions
   ("how exactly does tariff X displace tariff Y?") that are decisions, not code.
4. **Gate everything the same way:** spec-derived baseline must stay byte-identical to golden; new
   capabilities proven on a synthetic fixture (the drone/pharma pattern), exactly as Phase 6/8 did.

### Open questions for John
- **Target tier:** is the goal "behaves like a 232 with correct numbers" (Tier B) or "arbitrary
  type with clean provenance and partial displacement" (Tier C / Wire 2)?
- **Provenance tolerance:** is it acceptable for a new pharma-232 to live in the `rate_232` column
  (the cheap path), or must each new authority get its own column/identity?
- **Displacement semantics** (only if Tier C): for a non-metal new tariff, does it fully displace
  the reciprocal, or partially — and is that a per-tariff config or a fixed rule?
