# Review: HTS 2026 Revisions 14 and 15

**Reviewed 2026-08-07 against local `2026_rev_13` (published 2026-07-28).**
Status: **neither ingested.** The tracker's archive tip is rev_13, so the build
is **two releases behind** — one more than the release-currency gate permits.

| Release | Published | Superseded | Status |
|---|---|---|---|
| `2026_rev_13` | 2026-07-28 | 2026-07-31 | archived, in repo |
| `2026_rev_14` | 2026-07-31 | 2026-08-03 | archived, **JSON unobtainable** (see Method note) |
| `2026_rev_15` | 2026-08-03 | — | **current**, archive now committed |

## Verdict

Revision 14 **codifies the Section 232 pharmaceutical action (Proclamation
11020) into the tariff schedule** — 10 new Chapter 99 headings under a new
U.S. note 40 — and adds patented pharma to three existing §232-overlap
exclusion lists. Revision 15 changes exactly one thing: it corrects the rate
on the UK pharma heading.

The tracker already models this action, and the reconciliation is very good:
**the 131-HTS10 product list matches note 40(c) exactly, and the 100% / 15%
net-of-MFN structure matches the config's `target_total` semantics.** Two
findings are real:

1. **The UK pharma rate is wrong by 10 points** — config charges MFN + 10%,
   the schedule charges MFN + 0%. This is the one thing rev_15 changed.
2. **The 2026-09-29 date gate assumes every patented-pharma importer is on the
   Secretary's list** during 2026-07-31 → 09-28. Legally the 100% is live from
   07-31 for anyone *not* on that list.

Everything else is either already-correct modelling or cosmetic. Nothing blocks
the current build.

## What changed, rev_13 → rev_15 (combined)

| Dimension | rev_13 → rev_15 |
|---|---|
| Records | 35,779 → 35,788 (**+9**) |
| Keyed `htsno` entries | 29,835 → 29,844 |
| Chapter 99 headings | **+10 added, 0 removed, 0 modified** |
| HTS8 / HTS10 lines established or deleted (ch.1–97) | **0 / 0** |
| `general` rate changes, once markup is normalised | **0** |
| `other` (column 2) changes | **0** |
| `special` field changes | **0** |
| Description / `units` changes | 3,327, **all HTML markup** (see below) |

No 484(f) churn at all, so no HTS10-keyed resource file needs attention.

### The typographic pass (cosmetic, but it will bite a naive differ)

USITC ran a schedule-wide markup pass. Scientific names are now italicised,
units superscripted, and some descriptions carry inline styling:

- `Eels (Anguilla spp.)` → `Eels (<i>Anguilla spp.</i>)`
- `['m3', 'kg']` → `['m<sup style="font-size: 9.75px;">3</sup>', 'kg']`
- `6.8 kg` → `<il>6.8 kg</il>`, plus `<br />`, `<u>`, and one
  `<em style="color: rgb(51,51,51); font-family: …">Agaricus</em>`

A raw field-equality diff reports **3,199 modified entries**; after stripping
tags and normalising whitespace, **every one of them is cosmetic**. Any ad-hoc
revision comparison from here on needs tag-stripping before it can distinguish
a real rate change from this churn. Worth folding into
`tools/revision_changelog.R` before the next diff.

The tags land in `description` and `units`, not in `general`/`special`/`other`,
so the rate parsers are unaffected. Anything that *matches on description text*
should be re-checked — the annex parser
(`docs/s232/annex_parser.md`) is the obvious candidate.

## Revision 14 — Section 232 pharmaceuticals (PP 11020, U.S. note 40)

Per the change record, every item is sourced to **PP 11020** (April 2, 2026)
with effective date **2026-07-31**, except four `Notice`-sourced items.

### The 10 new headings (9903.04.60–.69)

| Heading | Rate as published | Scope (note 40) |
|---|---|---|
| `.60` | **100%** | Patented pharma, default. Net-of-MFN: total lands **at** 100% (40(d)) |
| `.61` | no additional duty | Companies **identified by the Secretary**, entered **before 2026-09-29** (40(e)) |
| `.62` | **15%** | Product of **Japan, EU member, South Korea, Switzerland, Liechtenstein**; net-of-MFN cap (40(f)) |
| `.63` | applicable subheading **+ 0%** | Product of the **United Kingdom** (40(g)) — **rev_15 corrected this rate** |
| `.64` | **+ 20%** | Company under a Commerce-**approved onshoring plan** (40(h)(i)) |
| `.65` | **+ 0%** | Onshoring plan **and** an HHS **MFN pricing agreement** (40(h)(ii)) |
| `.66` | **+ 0%** | Orphan drugs, nuclear medicines, plasma-derived, fertility, cell/gene, ADCs, CBRN countermeasures, animal health (40(h)(iii)) |
| `.67` | no additional duty | **Generic** pharmaceutical articles (40(c)(iii)) |
| `.68` | no additional duty | API in dosage form that is a **product of the United States** |
| `.69` | no additional duty | Articles in the note-40(c) list that are **not** pharmaceutical articles (40(i)) |

Note 40(a): the headings are **mutually exclusive** — an article falls under at
most one.

Note 40(b): duties are collected **in addition to** FTA/preference special
rates; chapter 98 claims stay eligible; and **no chapter 99 lower-rate or
duty-free claim is allowed** against these headings. AD/CVD continues to apply.

### Reconciliation against the tracker's model

`config/policy_params.yaml::section_232_headings.pharmaceuticals` has carried
this as a dormant, date-gated §232 sub-program since commit `84dd6ee`
(2026-06-07), fed from the proclamation rather than the schedule.

**Product scope — exact match.** `resources/s232_pharma_products.csv` (131
HTS10s) versus the note-40(c) enumeration (131 HTS10s):

> **0 in the note but missing from the file. 0 in the file but not in the note.**

**Rate structure — matches, and for a non-obvious reason.** The calculator
computes (`06_calculate_rates.R:399`):

```
rate_232 = max(country_rate, max(target_total - base_rate, 0))
           * (1 - generic_share) * (1 - exempt_share)
```

The `target_total` arm is exactly note 40(d)/(f): "for articles whose column 1
rate is less than the additional duty, the sum … shall be the rate provided by
the heading; where column 1 is greater, no additional duty is due." So
`target_total: {default: 1.00, CTY_JAPAN/eu/CTY_SKOREA/CTY_SWITZERLAND/
CTY_LIECHTENSTEIN: 0.15}` reproduces headings `.60` and `.62` correctly.

`generic_share` and `exempt_share` are the model's stand-in for headings `.67`
(generics) and `.66` (orphan/specialty) — the right shape, since those
carve-outs turn on facts the HTS cannot express.

### Finding 1 — the UK rate is 10 points too high

Config gives the UK `country_rates: {CTY_UK: 0.10}` with `target_total:
{CTY_UK: 0}`, so the resolved rate is `max(0.10, 0) = 10%` before shares, and
`0.10 × (1 − 0.20 generic) × (1 − 0.75 exempt) = 2.0%` after.

The schedule charges **the applicable subheading + 0%**, and note 40(g) carries
**no** net-of-MFN language, unlike (d) and (f). The UK additional duty is zero.

This is precisely what rev_15 changed. Its change record has exactly one line:

> `9903.04.63` | Modified (rates of duty) | July 31, 2026 | Notice

The modification is dated **effective 2026-07-31** — retroactive to rev_14's
own publication date — so there is **no split window** to model. The +0% is
operative from 07-31 onward, and the config's 10% is simply stale relative to
the correcting notice. Fix is a one-line config change (`CTY_UK: 0.0`), but it
moves the published series, so it belongs in a deliberate vintage.

### Finding 2 — the 09-29 gate over-exempts the 07-31 → 09-28 window

Heading `.61` gives relief only to companies **the Secretary identified**, and
only for entries **before 2026-09-29**. Heading `.60`'s 100% is otherwise live
from **2026-07-31**.

The tracker gates the whole pharma layer at `effective_date: '2026-09-29'`, so
it charges nothing for the eight weeks 07-31 → 09-28. That is correct only if
every importer of patented pharma is on the Secretary's list for that window.
The listed companies are presumably the majors negotiating onshoring deals, so
the *value-weighted* error is plausibly small — but it is an assumption, not a
reading of the text, and it is not currently written down.

Note-40(c) universe is **$160.4B of 2024 imports (5.1% of the panel)**, so the
window is not negligible in principle: a 100% duty on even a few percent of
that base for two months is material. This belongs in the deviations registry
with an explicit share, or the gate should move to 07-31 with a
`.61`-equivalent exempt share for the window.

### Already correct — the three §232-overlap exclusions

rev_14 also added, as item **(8)** in each of three lists, "patented
pharmaceutical articles provided for in headings 9903.04.60–9903.04.66":

| Note | Excludes pharma from | Repo status |
|---|---|---|
| `50(a)(vi)(8)` | §301 **Brazil** (9903.05.01, +25%) | **already modelled** |
| `52(f)(8)` | §301 **forced labor** (9903.05.20–.84, 10%/12.5%) | **already modelled** |
| `2(aa)(v)(1)` | §122 (9903.03.01, 10%) | **moot** — §122 expired 2026-07-23 |

The first two are already implemented, gated at exactly the right date:
`config/policy_params.yaml:867,937` carry `patented_pharma_exempt_date:
'2026-07-31'` pointing at the same 131-HTS10 list, and
`06_calculate_rates.R:1085` masks `rate_s301br` on it. The repo picked this up
from the Federal Register notice's Annex I Part B ahead of the HTS, and got the
subtle part right — the §301 relief starts **07-31** even though the §232 duty
only starts **09-29**, so it rides an explicit date-gated HTS10 list rather
than the `heading_program` arm. rev_14 is an independent confirmation of that
work, not a gap.

Note the exclusion spans `.60`–`.66`, which **includes the zero-rate headings**
`.63` (UK), `.65` (onshoring + MFN pricing) and `.66` (orphan/specialty). Those
goods pay no §232 pharma duty *and* shed the §301 surcharge. It does **not**
cover `.67` (generics), `.68` (US-origin API) or `.69` (non-pharma articles), so
those keep paying §301. The current implementation masks on the flat 131-HTS10
list, which cannot distinguish `.60`–`.66` from `.67`–`.69` — the same
approximation the `generic_share`/`exempt_share` parameters make elsewhere, but
worth noting since here it *removes* a §301 duty rather than adding a §232 one.

### Classification: pharma headings land in `other`

`classify_authority()` has no rule for `9903.04.xx` (`middle == 4`), so all ten
route to **`other`**, not `section_232` — verified by running it:

```
9903.04.60 -> other        9903.04.67 -> other
9903.04.63 -> other        9903.79.01 -> section_232   (semis, for contrast)
```

This is **numerically inert today**: no chapter 1–97 product line
footnote-references `9903.04` in rev_15 (checked), so the headings never attach
through the generic ch99 path, and the rate is config-fed. It is the same
situation the rev_12 review documented for Brazil's `9903.05.01`. But it does
mean the schedule cannot become the rate authority for pharma without a
`classify_authority()` rule — which is the natural next step now that the
headings exist, and the pattern is already established (Brazil in rev_12,
forced-labor tiers in the current working tree).

## What to do

1. **Fix the UK pharma rate** — `CTY_UK: 0.10` → `0.0` under
   `section_232_headings.pharmaceuticals.country_rates`. Moves the series from
   2026-09-29 onward; publish as a deliberate vintage.
2. **Decide the 07-31 → 09-28 window** — either move the gate to 07-31 with an
   explicit `.61` exempt share, or record the "all importers listed" assumption
   in the deviations registry. Do not leave it implicit.
3. **Ingest rev_15** (housekeeping). Archive is committed. Dating: publication
   is **2026-08-03**, but every substantive change is legally effective
   **2026-07-31**. Following the rev_13 precedent, add **rev_14 at
   `effective_date: 2026-07-31`** (that is the operative legal date and it owns
   the pharma headings) and **rev_15 at `2026-08-03`** with
   `policy_effective_date` empty — rev_15's only change is retroactive to 07-31
   and is a config fix, not a schedule-driven one, so it should be
   rate-neutral against rev_14 in the series.
4. **Teach the differ about markup** — strip tags in
   `tools/revision_changelog.R` before comparing, or the next changelog run
   reports 3,199 phantom modifications.
5. **Optional — make the HTS the pharma rate authority.** Add a
   `classify_authority()` rule for `9903.04.6x` → `section_232` and read the
   `.60`/`.62`/`.63`/`.64` rates off the schedule, demoting config to fallback.
   This is exactly what the working tree is doing for the forced-labor tiers,
   and it would have caught Finding 1 automatically.

## Method notes

**rev_14's JSON cannot be retrieved.** `exportList` serves only the *current*
release and the static archive host has returned Akamai 403 since June 2026, so
rev_14 — current for three days — is permanently unobtainable through the
documented paths. The practical loss is one heading's rate (`9903.04.63` at its
pre-correction value), because rev_15's own change record confirms that is the
*only* difference between them. Recorded here so the gap in
`data/hts_archives/` is understood rather than rediscovered.

**Change records are reachable, and this is new.** The blocked static path
(`usitc.gov/sites/default/files/tata/hts/...`) has a working replacement on the
reststop host, and it serves **archived** releases, not just the current one:

```
https://hts.usitc.gov/reststop/file?release=2026HTSRev14&filename=Change%20Record
https://hts.usitc.gov/reststop/file?release=currentRelease&filename=Chapter+99
```

Both rev_14 and rev_15 change records were fetched this way and are committed to
`data/hts_change_record/`. This is worth wiring into
`src/pipeline/02_download_hts.R` — it is the only route to per-revision
attribution now that the JSON diff can only ever show a *combined* delta across
missed releases.

**The new files need `git add -f`.** `.gitignore:19` ignores
`data/hts_archives/*.json.gz` and `:22` ignores `data/hts_change_record/`
entirely, even though the comment directly above says the gzipped archives "ARE
committed" — the existing ones are tracked because they were force-added. So the
files placed by this review are on disk but invisible to `git status`:

```
git add -f data/hts_archives/hts_2026_rev_15.json.gz \
           'data/hts_change_record/Change Record_2026HTSRev14.pdf' \
           'data/hts_change_record/Change Record_2026HTSRev15.pdf'
```

**Provenance assertion.** The rev_13 review's guard still applies and still
matters: `exportList` needs the full range (`from=0101.21.00&to=9999.00.00`) or
it silently drops all of Chapter 99. Verified on the new archive — 35,788
records, 10 `9903.04.6x` headings, `9903.05.01` present. One artifact of that
range: the bare heading row `0101` sorts before `from=0101.21.00` and is absent
from the rev_15 export while present in rev_13's. It is a superior/heading row
with an empty `general` field, so it carries no rate and no product line, but it
does show up as a spurious "1 removed" in any keyed diff.
