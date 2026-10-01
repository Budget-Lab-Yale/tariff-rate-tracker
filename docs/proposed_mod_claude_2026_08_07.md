# Proposed modifications: HTS rev_14/rev_15 ingest, §232 pharma corrections, §232 polysilicon, and the expired Solar 201 safeguard

**Status: PROPOSAL — nothing here is implemented.** Written 2026-08-07 from two
reviews completed the same day:

- `docs/internal/hts_2026_rev14_rev15_review.md` — HTS 2026 rev_14 (2026-07-31)
  and rev_15 (2026-08-03, current). Archive tip was rev_13, so the build was two
  releases behind.
- `docs/internal/polysilicon_232_review_2026-08-06.md` — the §232 polysilicon
  proclamation of 2026-08-06, effective 2026-12-04.

Two notes on what is and is not alongside this document:

- **The rev_15 archive and change records are on disk but NOT committed.**
  `data/hts_archives/hts_2026_rev_15.json.gz` and the rev_14/rev_15 change
  records in `data/hts_change_record/` are gitignored by pattern (`.gitignore:19,22`)
  and need `git add -f`, as the existing archives did. Preflight is green with
  them present (89 archives). **This matters on a clock:** `exportList` serves
  only the *current* release, so once USITC publishes rev_16, rev_15's JSON
  becomes unobtainable exactly as rev_14's already is. They should be
  force-added with the M4 ingest at the latest.
- **`docs/internal/hts_2026_rev13_review.md`, cited below, is not on `master`** —
  it lives on `feat/ingest-2026-rev13` and arrives when that branch merges. Every
  code and config anchor in this proposal was verified against `master`.

**Headline: one live error, two corrections, one new authority.** Ranked by
magnitude, not by how the work arrived:

| # | Change | Status of the underlying fact | Series impact |
|---|---|---|---|
| **M1** | Date-gate Section 201 at its 2026-02-06 expiry | **CONFIRMED** — safeguard terminated; HTS stamped since rev_4 | **−14.5% on $16.6B from 2026-02-07**; ~−0.08pp weighted ETR |
| **M2** | UK §232 pharma rate 10% → 0% | **CONFIRMED** — heading 9903.04.63 reads "+ 0%" | small, from 2026-09-29 |
| **M3** | Resolve the 2026-07-31 → 09-28 pharma window | **OPEN QUESTION** — needs a decision, not a fix | up to 100% on part of a $160B base for 8 weeks |
| **M4** | Ingest rev_14 + rev_15 rows | housekeeping | +2 partitions, else rate-neutral |
| **M5** | New `section_232_headings.polysilicon` program | not yet in any HTS revision | from 2026-12-04 |
| **M6** | Tooling: markup-stripping differ, change-record fetch, `classify_authority` rules | housekeeping | none |

Guiding principles, in the order they were applied:

1. **Hew to the statutory language.** Every change below is anchored to a
   specific ch99 heading and note subdivision, quoted verbatim. Where the note
   and the model disagree, the note wins.
2. **Separate "wrong now" from "forthcoming."** M1 is a defect in the published
   series. M5 is a new authority that does not bind until December. They should
   not ride the same vintage.
3. **Do not launder an open question into a code change.** M3 is a modelling
   decision with a real magnitude and no obviously right answer; the proposal
   states the options and the evidence, and stops.
4. **Reuse the established pattern.** Every mechanism proposed here already
   exists in the repo for another authority (§122 expiry, s338 segment matching,
   pharma date-gating, the 484(f) weight mapper). Nothing new is invented.

---

## 1. The findings in one place

Two things reconciled **exactly**, and they are worth stating first because they
constrain everything else:

- **Pharma product scope: 0 mismatches.** `resources/s232_pharma_products.csv`
  (131 HTS10s) against the U.S. note 40(c) enumeration (131 HTS10s) — nothing in
  the note is missing from the file, nothing in the file is absent from the note.
- **Pharma rate structure: matches, non-obviously.** Note 40(d)/(f) is a
  net-of-MFN *total*, and the calculator's `target_total` arm
  (`06_calculate_rates.R:399`) already implements exactly that:

  ```
  rate_232 = max(country_rate, max(target_total - base_rate, 0))
             * (1 - generic_share) * (1 - exempt_share)
  ```

  So `target_total: {default: 1.00, CTY_JAPAN/eu/CTY_SKOREA/
  CTY_SWITZERLAND/CTY_LIECHTENSTEIN: 0.15}` reproduces headings `.60` and `.62`
  correctly, and `generic_share`/`exempt_share` stand in for `.67`/`.66`.

And one thing that was **already right and is now independently confirmed**:
rev_14 added "patented pharmaceutical articles provided for in headings
9903.04.60–9903.04.66" as item **(8)** to the §232-overlap exclusions in note
50(a)(vi) (Brazil §301) and note 52(f) (forced-labor §301). The repo implements
this from the FR notice's Annex I Part B — `patented_pharma_exempt_date:
'2026-07-31'` at `config/policy_params.yaml:867,937`, masked at
`06_calculate_rates.R:1085` — and got the subtle part right: §301 relief starts
**07-31** even though the §232 duty starts **09-29**. The parallel note
2(aa)(v)(1) §122 exclusion is moot (§122 expired 2026-07-23). **No change
proposed.**

---

## 2. M1 — Date-gate Section 201 (the live error)

### 2.1 The fact

The CSPV safeguard **terminated 2026-02-06** at the eight-year statutory maximum
(§203(e)(1)(B) of the Trade Act; Proc. 9693 four years from 2018-02-07, Proc.
10454 four more). USITC instituted **TA-201-075** to evaluate the relief action
"which terminated on February 6, 2026" ([91 FR, 2026-03-17](https://www.federalregister.gov/documents/2026/03/17/2026-05170/crystalline-silicon-photovoltaic-cells-whether-or-not-partially-or-fully-assembled-into-other)).

The repo's own archives have carried the evidence since February:

> `9903.45.22` Other **[Compiler's note: This subheading and its related note,
> U.S. note 18 to this subchapter, have expired. See 87 Fed. Reg. 7357.]**

The stamp first appears in **`2026_rev_4`** (2026-02-24), absent from
`2026_rev_3` (2026-02-12). As of rev_15 there is **no live CSPV provision
anywhere in Chapter 99**. (The 87 FR cite looks stale but is not — it points at
the proclamation that set note 18's terminal date; the *stamp* is what is new.)

### 2.2 Why the model misses it

Two mechanisms independently fail:

- `extract_section_201_rates()` sets `has_s201 = TRUE` on the mere **presence**
  of `9903.45.21–.29`, and they are still present as shaded historical entries.
  The rate then comes from config by design — the override exists precisely
  because the HTS shows the stale 30% Year-1 rate.
- `filter_active_ch99()` drops entries whose `expiry_date_offset` precedes the
  revision date, but `extract_expiry_date_offset()` (`rate_schema.R:423`) only
  matches `(through|on or before|before) <Month> <D>, <YYYY>`. The compiler's
  note carries **no date**, so the parser returns `NA`. Verified:

  ```
  extract_expiry_date_offset("… have expired. See 87 Fed. Reg. 7357.") -> NA
  ```

So `apply_section201()` (`06_calculate_rates.R:1243–1268`) applies
`section_201.solar_rate: 0.145` flat across the entire series. A grep for any
date, expiry, or window handling on `section_201` returns nothing;
`policy_params.R:334` passes the block through verbatim.

### 2.3 Magnitude

Every snapshot dated after 2026-02-06 charges 14.5% where it should charge zero,
on the three lines in `resources/s201_solar_products.csv`:

| HTS10 | 2024 imports |
|---|---|
| `8541430010` + `8541430080` (modules) | $14.81B |
| `8541420010` (cells) | ~$1.8B |
| **Total** | **~$16.6B** |

≈ **$2.4B/yr of phantom duty**, ≈ **0.08pp of weighted ETR** (14.5% × 0.533% of
the panel), for every date from 2026-02-07 onward.

### 2.4 Proposed change

Mirror the `section_122` expiry pattern, which already has every piece wired.

**(a) Config** — `config/policy_params.yaml`, `section_201` block:

```yaml
section_201:
  solar_rate: 0.145
  # Solar 201 (Proc 9693 + Proc 10454) TERMINATED 2026-02-06 at the §203(e)(1)(B)
  # eight-year statutory maximum; USITC TA-201-075 evaluates the relief "which
  # terminated on February 6, 2026". USITC stamped the expiry onto 9903.45.21-.29
  # at 2026_rev_4 (2026-02-24), but the stamp carries no DATE, so
  # extract_expiry_date_offset() returns NA and filter_active_ch99() cannot drop
  # the headings — hence an explicit gate here. Last active day:
  expiry_date: '2026-02-06'
  policy_expiry_date: '2026-02-06'
  finalized: false
```

**(b) Params loader** — `src/model/policy_params.R:334`, alongside the existing
pass-through, adopting the `section_122` idiom at `:304,319`:

```r
if (!is.null(params$section_201)) {
  params$SECTION_201 <- params$section_201
  if (!is.null(params$section_201$expiry_date))
    params$SECTION_201$expiry_date <- as.Date(params$section_201$expiry_date)
  if (!is.null(params$section_201$policy_expiry_date)) {
    params$SECTION_201$expiry_date <- as.Date(params$section_201$policy_expiry_date)
    message('  Policy dates: S201 expiry -> ', params$SECTION_201$expiry_date)
  }
}
```

**(c) The gate itself.** Two options; **prefer (c-ii)**.

- **(c-i) Gate in `apply_section201()`.** Add an `effective_date` argument and
  return `rates` untouched when `effective_date > expiry_date`. Local and
  obvious, but it puts a date test in the calculator where the other authorities
  express liveness through their spec.
- **(c-ii) Gate on the spec's `active$until` — preferred.** `section_201` is
  built as an `authority_spec` at `authority_adapter.R:1157` with
  `active = list(from = NA, until = NA)`. Setting
  `until = pp$SECTION_201$expiry_date + 1` makes it declarative and gets the
  **boundary mint for free**: `collect_schedule_boundaries()` already reads
  `s$active$until` for every spec (`timeline.R:82–86`) and applies
  `boundary_from_until()`. This is the same information path the §122 sunset
  uses.

  **Prerequisite to verify before choosing (c-ii):** confirm that `active$until`
  is actually *enforced in the rate calculation* and not merely consumed for
  boundary collection. `collect_schedule_boundaries()` demonstrably reads it;
  I have **not** traced whether `apply_section201()` (or a wrapper) honours it.
  If it does not, (c-ii) becomes "wire the spec gate, then rely on it" — still
  the better shape, but a larger change than (c-i), and it would want a test
  asserting a spec with a past `active$until` contributes zero rate.

**(d) Boundary mint.** Under (c-ii) this is automatic. Under (c-i), add
`'2026-02-07'` to `boundary_overrides` (`config/policy_params.yaml:995`) so the
drop materialises as its own partition rather than waiting for the next
revision.

### 2.5 Open sub-question — the Year-8 rate

Secondary sources put the final safeguard year (2025-02-07 → 2026-02-06) at
**14%**; config carries **14.5%**. This is moot for dates after expiry but
affects **2025-02-07 → 2026-02-06**, which is inside the published series. Worth
confirming against the USTR step-down notice while M1 is open. Not proposed as a
change — the evidence I have is secondary, and the config comment ("update
annually based on USTR notice") suggests the 14.5% was entered deliberately.

---

## 3. M2 — UK §232 pharma rate: 10% → 0%

**The fact.** Heading `9903.04.63` reads "The duty provided in the applicable
subheading **+ 0%**", and note 40(g) carries **none** of the net-of-MFN language
that 40(d) and 40(f) have:

> (g) Heading 9903.04.63 applies to patented pharmaceutical articles that are
> the product of the United Kingdom that would otherwise be subject to the
> additional duties imposed under heading 9903.04.60.

**Why this is the one thing rev_15 changed.** rev_15's change record has exactly
one line:

> `9903.04.63` | Modified (rates of duty) | July 31, 2026 | Notice

Dated **effective 2026-07-31** — retroactive to rev_14's own publication date —
so there is **no split window** to model. The +0% is operative from 07-31
onward. The config's 10% reflects PP 11020 as proclaimed and is now stale
relative to the correcting notice.

**Current resolution.** With `country_rates: {CTY_UK: 0.10}` and `target_total:
{CTY_UK: 0}`, the resolved rate is `max(0.10, 0) = 10%` before shares and
`0.10 × (1 − 0.20 generic) × (1 − 0.75 exempt) = 2.0%` after.

**Proposed change** — `config/policy_params.yaml:196–197`:

```yaml
    country_rates:
      # Heading 9903.04.63 / note 40(g): the UK additional duty is ZERO — "the
      # duty provided in the applicable subheading + 0%", with no net-of-MFN
      # clause (contrast 40(d)/(f)). Was 0.10 from PP 11020 as proclaimed; HTS
      # rev_15 corrected the heading rate effective 2026-07-31 (retroactive to
      # rev_14), so there is no split window.
      CTY_UK: 0.0
```

Leave `target_total: {CTY_UK: 0}` as-is — with `country_rates` at zero the
`max()` resolves to zero either way, and removing it would change the shape of
the block for no gain.

Moves the series from 2026-09-29 onward (or from 07-31 if M3 lands first).
**Publish as a deliberate vintage.**

---

## 4. M3 — The 2026-07-31 → 09-28 pharma window (decision required)

**This is an open question, not a proposed change.**

The model gates the whole pharma layer at `effective_date: '2026-09-29'`
(`config/policy_params.yaml:194`), so it charges nothing for the eight weeks
from 07-31. The statute does not read that way:

> **(e)** Heading 9903.04.61 applies to patented pharmaceutical articles
> imported for companies **identified by the Secretary** and imported **before
> 12:01 am eastern time on September 29, 2026**.

Heading `.61` carries no additional duty; heading `.60`'s **100%** is otherwise
live from **2026-07-31**. So the current gate is correct **only if every
importer of patented pharma is on the Secretary's list** for that window.

**Magnitude.** The note-40(c) universe is **$160.4B of 2024 imports (5.1% of the
panel)**. A 100% duty on even a few percent of that base for two months is
material, so this cannot be waved through on immateriality.

**Countervailing consideration.** The listed companies are presumably the majors
negotiating onshoring agreements, which plausibly covers most of the *value*.
The current treatment may be approximately right — but it is currently an
accident of the gate date, not a modelled position.

**Options.**

- **(a) Keep 09-29, document it.** Add a `docs/statutory_deviations.md` entry
  stating the assumption ("all patented-pharma importers treated as
  Secretary-identified for 2026-07-31 → 09-28") with the $160.4B base and the
  reasoning. Zero series change. Cheapest, and honest.
- **(b) Move the gate to 07-31 with a `.61` exempt share.** Add a
  date-bounded share representing the non-listed fraction, and stop applying it
  at 09-29. Correct in shape; needs a number nobody currently has.
- **(c) Move the gate to 07-31 with no share.** Charges 100% to everyone for the
  window. Almost certainly wrong in the other direction.

**Recommendation: (a) now, (b) if and when Annex III of PP 11020 or the
Secretary's CBP notification becomes available** — that list is the only thing
that would make the share more than a guess. Whichever is chosen, it should be
written down; leaving it implicit is the one option to reject.

---

## 5. M4 — Ingest rev_14 and rev_15

Housekeeping. `config/revision_dates.csv` gains two rows:

| revision | `effective_date` | `policy_effective_date` | rationale |
|---|---|---|---|
| `2026_rev_14` | `2026-07-31` | *(empty)* | Publication **and** operative legal date coincide; owns the pharma headings |
| `2026_rev_15` | `2026-08-03` | *(empty)* | Publication date; its sole change is retroactive to 07-31 |

Notes on the dating, following the rev_12/rev_13 precedents:

- `2026-07-31` is **already in `boundary_overrides`**
  (`config/policy_params.yaml:995`) for the §301 pharma exclusion, so rev_14's
  own date coincides with an existing mint. Per the rev_12 comment, an
  edge-coincident `policy_effective_date` can be dropped by
  `discover_boundaries` (`owner_of`) — hence leaving it empty and letting
  `effective_date` carry the date.
- rev_15 should be **rate-neutral against rev_14** in the series once M2 lands,
  because its only change is the UK heading and that is config-fed.
  **This is the acceptance check**: a rate difference on any pre-08-03 partition
  means something was missed.
- **rev_14's JSON is unobtainable** — `exportList` serves only the current
  release, and the static archive host has 403'd since June 2026. rev_14 was
  current for three days. Its change record confirms the *only* difference from
  rev_15 is `9903.04.63`'s rate, so the practical loss is that one value. The
  archive gap should be recorded in `docs/revision_changelog.md` rather than
  rediscovered.

Expected build result: **two new partitions** (`valid_from` 2026-07-31 and
2026-08-03), every earlier partition **identical** to the current vintage.

---

## 6. M5 — New authority: §232 polysilicon (effective 2026-12-04)

Not in any HTS revision yet, so this is hand-fed from the proclamation on the
established pharma/Brazil/s338 pattern. Nothing binds before December.

### 6.1 Structure to model

| Heading | Rate as written | Scope | Semantics |
|---|---|---|---|
| `.30` | applicable subheading **+ 15%** | wafers, cells, modules — all other origins | **Additive** (note 42 has no cap clause for `.30`) |
| `.31` | **15%** | LI, JP, KR, CH, **TW**, EU members | **Total capped at 15%** (note 42(c)) |
| `.32` | applicable subheading **+ 10%** | United Kingdom | **Additive**, no cap |

> **(c)** For articles provided for in heading 9903.45.31 with a column 1 rate
> of duty less than 15 percent, the sum of the column 1 rate of duty and the
> additional ad valorem rate of duty pursuant to heading 9903.45.31 will total
> 15 percent ad valorem.

**The `.30`/`.31` asymmetry is the thing to get right, and it is *not* the pharma
pattern.** Note 40(d) caps the default heading; note 42 caps only the
framework-partner heading. So the pharma block's
`max(country_rate, target_total − base_rate)` resolves the **wrong way** for an
additive default — at a 3% MFN line, `.30` should yield 18% total, and a
`target_total: 1.00`-style read would yield 15%. This needs an additive default
alongside a `target_total` tier, which the current config vocabulary does not
express in one block. **This is the main design question in M5** and should be
settled before writing config.

**Scope.** `.30`/`.31`/`.32` cover the wafer + cell + module lines but **not**
`2804.61.0000` — raw polysilicon appears in **no** ad valorem heading, only in
the MIP heading `.33`.

**Stacking.** `usmca: none`. Annex II modifies **no other note**: polysilicon is
added to none of the §232-overlap exclusion lists (note 2(v), 2(aa)(v),
50(a)(vi), 52(f)) — unlike every other sectoral §232 action. There is no
displacement of any other authority. Note 42(b) mirrors 40(b): additive to
FTA/preference special rates, ch98 claims eligible, no ch99 lower-rate claim
allowed, AD/CVD continues.

### 6.2 The MIP layer — propose a documented zero

| Heading | Scope | Specific duty |
|---|---|---|
| `.33` | `2804.61.0000` | + **$21/kg** |
| `.34` | `3818.00.0020/.0040/.0045/.0050/.0091` | + **$100/kg** |
| `.35` | `8541.42.00` | + **$0.22/watt** |
| `.36` | `8541.43.00` | + **$0.38/watt** |

These are a **price-floor enforcement backstop**, not a duty most importers pay.
Note 42(a) makes them inapplicable where entered value meets or exceeds the
specific rate **and** the goods will not be resold below it (or ride a
pre-2026-08-06 fixed-term contract); they apply when the importer "fails to
submit documentation concerning the resale … or if the importer submits such
documentation but CBP is required to adjust."

Two independent blockers to representing them:

- `parse_rate()` collapses every non-ad-valorem rate to `NA` with a
  `specific_or_compound` flag (`helpers.R:93,118`); the tracker is ad valorem
  throughout (`base_rate` coalesces missing MFN to 0, `rate_schema.R:104`).
- Conversion to ad-valorem-equivalent needs **quantity**, and the
  watt-denominated rates need **capacity**, which the HTS10 value panel does not
  carry at all.

**Proposal: model the ad valorem layer, and represent the MIP as an explicit,
documented zero** with a named compliance-share parameter for later calibration
— the shape already used for the Note 39 semiconductor tech gate
(`semi_qualifying_shares.csv`, default 1.0 uncalibrated). A zero is defensible
here because a compliant importer genuinely pays nothing; an uncalibrated
per-unit duty pushed through a guessed quantity is not. Add a
`docs/statutory_deviations.md` entry saying so.

### 6.3 Prerequisite — the 3818.00.00 weight gap

Annex I and heading `.34` cite five statistical suffixes that **carry no weight
in the concordance**:

| | |
|---|---|
| rev_15 HTS has | `3818.00.00.20`, `.30`, `.40`, `.45`, `.50`, `.91` |
| 2024 GTAP panel has | only `3818000090` (**$1.39B**) and `3818000010` ($0.14B) |

As written, the wafer layer — the **largest per-unit rate in the action** —
would attach to a base of **zero**, silently dropping $1.39B of exposure. This
is the 484(f) versioned-identity failure mode the rev_11 changelog entry already
flags ("GTAP weights concordance (176/179 new codes absent)"); the 484(f) weight
mapper (`15646c6`) is the machinery. **Check `data/484f/source_manifest.csv`
first** — the split may already be recorded.

### 6.4 Exposure

2024 imports, `data/weights/hs10_by_country_gtap_2024_con.rds` (panel total
$3,123.8B):

| Layer | HTS10s present | 2024 imports | Share |
|---|---|---|---|
| Solar **modules** `8541.43` | 2 | **$14.81B** | 0.474% |
| Solar **cells** `8541.42` | 2 | $1.83B | 0.059% |
| **Polysilicon** `2804.61` | 1 | $0.13B | 0.004% |
| **Wafers** `3818.00` | **0** | **$0.00B** | — |
| **Total** | | **$16.77B** | **0.537%** |

Modules are 88% of it. Note this is **the same $16.6B** that M1 is currently
over-taxing — the two changes act on one product set in opposite directions, and
M1 should land first so its effect is not confounded with a new authority.

---

## 7. M6 — Tooling and classification

None of these change a rate; all of them prevent a future silent error.

**(a) Strip HTML markup in `tools/revision_changelog.R` — do this before the
next changelog run.** USITC ran a schedule-wide typographic pass (italicised
scientific names, `<sup>` units, `<br />`, one `<em style=…>`). A raw field diff
across rev_13 → rev_15 reports **3,199 modified entries; every one is cosmetic**
once tags and whitespace are normalised. Without this the next run is
unreadable. Tags land in `description` and `units` only, not
`general`/`special`/`other`, so rate parsers are unaffected — but **re-check
anything that matches on description text**; the §232 annex parser
(`docs/s232/annex_parser.md`) is the candidate.

**(b) Wire the working change-record endpoint into
`src/pipeline/02_download_hts.R`.** The blocked static path has a replacement on
the reststop host that serves **archived** releases, not just the current one:

```
https://hts.usitc.gov/reststop/file?release=2026HTSRev14&filename=Change%20Record
https://hts.usitc.gov/reststop/file?release=currentRelease&filename=Chapter+99
```

This is the **only** route to per-revision attribution once a release has been
missed — a JSON diff can then only ever show a combined delta. It is how rev_14
was attributed at all.

**(c) `classify_authority()` — two gaps** (`src/model/rate_schema.R`). Both are
**latent, not live**: no chapter 1–97 product line footnote-references either
block in rev_15 (checked — the only `9903.45` references are self-references
inside Chapter 99), and both rates are config-fed. Verified behaviour:

```
9903.04.60 -> other          9903.45.30 -> section_201
9903.04.63 -> other          9903.45.33 -> section_201
9903.79.01 -> section_232    (semiconductors, for contrast)
```

- **Pharma `9903.04.6x` → `other`** (no rule for `middle == 4`). Same situation
  the rev_12 review documented for Brazil's `9903.05.01`. A rule is the
  prerequisite for making the schedule the pharma rate authority (M6d).
- **Polysilicon `9903.45.3x` → `section_201`**, because Solar 201 owns the whole
  `9903.40–45` range (`rate_schema.R:344`). Add a **segment** rule
  (`parts[2] == 45 && parts[3] %in% 30:36` → `section_232`) **before** the
  Section 201 bucket, following the `section_338` precedent at
  `rate_schema.R:298` — whose docstring already explains why segment-matching
  beats string-matching here. Rate extraction is safe either way:
  `extract_section201_rates()` restricts to `.21–.29`
  (`05_parse_policy_params.R:1275`).

**(d) Optional — make the HTS the pharma rate authority.** With a
`classify_authority()` rule in place, read `.60`/`.62`/`.63`/`.64` off the
schedule and demote config to fallback. This is exactly what the working tree is
doing for the forced-labor tiers, and **it would have caught M2
automatically** — which is the strongest argument for it.

**(e) Residual nuance, recorded not proposed.** The §301 pharma exclusion spans
`.60`–`.66` only, so generics (`.67`), US-origin API (`.68`) and non-pharma
articles in the note-40(c) list (`.69`) still owe §301. The current
implementation masks on the flat 131-HTS10 list and cannot distinguish them.
Worth noting because here the approximation **removes** a §301 duty rather than
adding a §232 one, and the exclusion covers the zero-rate headings `.63` (UK),
`.65` and `.66` — those goods pay no §232 pharma duty *and* shed the §301
surcharge.

---

## 8. Sequencing

Ordered so each step's effect is separable in the parity gate.

1. **M1 (Solar 201 gate) alone, as its own vintage.** It is the only live error,
   it is the largest number here, and it moves the same product set M5 will
   later touch. Landing it separately is what keeps the two attributable.
   Acceptance: a single new partition at 2026-02-07; `rate_section_201` → 0 on
   the three solar HTS10s from that date; every pre-02-07 partition byte-identical.
2. **M6a + M6b (differ, change-record fetch).** No rate impact, and M6a is a
   prerequisite for reading the next revision diff at all.
3. **M4 + M2 together.** The ingest and the UK correction are both about rev_14/
   rev_15 and the acceptance check for M4 (rev_15 rate-neutral vs rev_14) is
   cleanest once M2 has removed the known-stale value. Acceptance: two new
   partitions; no pre-07-31 partition moves.
4. **M3 decision.** Written down before or with step 3; if option (b) is chosen
   it changes the series and needs its own vintage.
5. **M6c (+ optionally M6d).** Classification hygiene, no rate impact — but M6c
   for `9903.45.3x` must precede M5.
6. **M5 (polysilicon), plus its 6.3 prerequisite.** Not urgent: nothing binds
   until 2026-12-04. Settle the additive-vs-capped design question (6.1) and the
   3818.00.00 weight mapping (6.3) first, or the layer will attach to a zero base.

Each rate-moving step follows the established gate: build to a validation root,
`scripts/run_parity_check.R` against the current `latest`, review, then repoint
deliberately with `Rscript scripts/publish_vintage.R --latest-only <vintage>`.
Per `CLAUDE.md`, full rebuilds go to Slurm (`sbatch scripts/submit_build_verify.sh`,
192 GB) — they OOM in an interactive session.

---

## 9. What this proposal explicitly does NOT do

- **It does not implement anything.** No config, code, or `revision_dates.csv`
  edits have been made. The only filesystem changes are the rev_15 archive, the
  two change records, the two review docs, and `todo.md` entries.
- **It does not decide M3.** The window is a modelling judgement with a real
  magnitude; §4 lays out the options and recommends, but the call is the
  curator's.
- **It does not settle the Year-8 Solar 201 rate** (14% vs 14.5%, §2.5). The
  evidence is secondary and the config value looks deliberate.
- **It does not attempt the MIP layer** beyond a documented zero (§6.2), and
  does not propose an ad-valorem-equivalent conversion. Quantity and capacity
  data are absent; a guessed conversion would be worse than an explicit zero.
- **It does not model the polysilicon proclamation's non-tariff machinery** —
  manufacturing drawback for Trade Agreement Partners (19 U.S.C. 1313(a)–(b)),
  FTZ privileged-status admission (19 C.F.R. 146.41), onshoring tariff offsets
  (construction start by 2029-01-20), or substantially-equivalent-MIP
  arrangements. Recorded so they are not mistaken for gaps.
- **It does not revisit the `9903.05.2x`/`9903.06.xx` forced-labor
  classification** (they route to `section_301_brazil` / `other`), which the
  rev_13 review already covers and the working tree is actively changing.
- **It does not touch the uncommitted working tree** — the rev_13 forced-labor
  rate-sourcing changes in `authority_adapter.R`,
  `05_parse_policy_params.R` and `tests/test_rate_calculation.R` are untouched
  and unreviewed here.
