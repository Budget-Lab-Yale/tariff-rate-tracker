# Review: HTS 2026 Revision 13 (published 2026-07-28)

**Reviewed 2026-07-31 against local `2026_rev_12` (published 2026-07-21).**
Status: **not yet ingested.** The tracker's tip is rev_12, so the build is
exactly one release behind — which the release-currency gate permits.

## Verdict

Revision 13 **codifies the Section 301 forced-labor final action into the
tariff schedule**. It adds 101 Chapter 99 headings and changes nothing else of
substance. The tracker already models this action as a baseline authority from
the Federal Register notice, and a line-by-line reconciliation found **zero rate
discrepancies** against what USITC published. No new modelling is required; what
remains is housekeeping plus two optional improvements.

## What changed

| Dimension | rev_12 → rev_13 |
|---|---|
| Records | 35,677 → 35,778 (**+101**) |
| Chapter 99 headings | 511 → 612 (**+101 added, 0 removed, 0 modified**) |
| HTS8 lines established / deleted | **0 / 0** |
| HTS10 lines established / deleted | **0 / 0** |
| `general` rate changes on ch.1–97 lines | **0** |
| `special` field changes | 25, all pure whitespace normalisation (embedded newline → space). No programme codes added or removed. **No action.** |
| `other` (column 2) changes | 0 |

No 484(f) churn at all, which is unusual for a revision and means none of the
HTS10-keyed resource files need attention.

### The 101 new headings

**64 country charging headings** (`9903.05.20`–`.84`), one per investigated
economy, keyed to the new **U.S. note 52**:

- **40 at `+12.5%`** — e.g. Algeria, Angola, Australia, Bahamas, Bahrain,
  Brazil, Chile, China, Colombia, Egypt, Hong Kong, Türkiye
- **19 at `+10%`** — e.g. Argentina, Bangladesh, Cambodia, Canada, Ecuador,
  El Salvador, Guatemala, Honduras
- **The EU is bifurcated rather than rate-capped arithmetically**:
  `9903.05.38` (EU lines whose column-1 rate is at or above the threshold →
  "the duty provided in the applicable subheading", i.e. no additional duty) and
  `9903.05.39` (EU lines below it → a flat `10%` replacing the column-1 rate).
  This is CBP implementing a net-of-MFN cap by splitting headings instead of
  doing arithmetic. It is equivalent to the tracker's `max(10% − MFN, 0)`
  formulation: where MFN ≥ 10% the add-on is zero, and where MFN < 10% the total
  lands exactly on 10%.

**15 exemption headings** (`9903.05.85`–`.99`): in-transit goods (loaded before
12:01 a.m. ET **2026-07-24** — this is the operative legal effective date),
note 52(b) and 52(c) lists, civil aircraft, pharmaceutical use, a **§232-overlap
carve-out** covering steel/aluminium/copper and derivatives plus passenger
vehicles and light trucks, donations, informational materials, and
country-specific relief for Canada 52(g), Mexico 52(h), CAFTA-DR textiles for
the note-52(i) six (CR/DO/SV/GT/HN/NI), the UK, the EU, Switzerland and Malaysia.

**21 product carve-out headings** (`9903.06.01`–`.21`): per-country product
lists referenced from the charging headings — Malaysia, Cambodia, Guatemala,
El Salvador, Argentina, Bangladesh, Ecuador and others.

## Reconciliation against the tracker's model

`config/policy_params.yaml::section_301_forced_labor` already carries
`effective_date: '2026-07-24'`, cites headings 9903.05.20–.84 and note 52, and
sorts origins into flat-10, net-of-MFN-10, net-of-MFN-12.5 and implicit-flat-12.5
tiers.

Every one of the 64 charging headings was mapped to its Census origin code and
its HTS rate compared with the tier the config assigns:

> **0 mismatches.**

Three names needed manual confirmation and all three are correct:

- `9903.05.38` / `.39` — "European Union" as a collective heading; the config
  enumerates the 27 member-state Census codes individually in the net-10 tier
  (28 entries = EU-27 + Taiwan).
- `9903.05.79` — "Türkiye", spelled "Turkey" in `resources/census_codes.csv`
  (code 4890). It appears in no explicit tier, so it falls to the implicit flat
  12.5%, which is what the HTS charges.

The 2026-07-24 turn-on is already live in the published series: the current
vintage carries a `valid_from=2026-07-24` partition.

## What to do

1. **Ingest rev_13** (housekeeping). Add the revision row and fetch the archive.
   Dating: the HTS revision is published **2026-07-28** while the duty is legally
   effective **2026-07-24** — a four-day retroactive window. The duty is already
   turned on at 07-24 from config, so `effective_date: 2026-07-28` with
   `policy_effective_date` left empty is correct and numerically neutral; dating
   the row 07-24 would collide with the existing boundary at that date.
2. **Optional — re-source the rates from the HTS.** rev_12 did exactly this for
   the Brazil action ("the +25% now reads off HTS 9903.05.01 …; config rate
   demoted to fallback"). The same is now possible for the forced-labor tiers,
   which would make the schedule the rate authority and leave config as a
   fallback. Numerically neutral if the reconciliation above holds — and it does.
3. **Optional — cross-check the 21 `9903.06.xx` carve-outs** against the
   4,921-row `resources/s301fl_final_country_exemptions.csv`, which was built
   from the Federal Register annex. The HTS references these lists by note-52
   subdivision, so USITC's enumeration is an independent check on ours.

Nothing here is a defect and nothing blocks the current build.

## Method note

The USITC `exportList` endpoint requires the repo's full range
(`from=0101.21.00&to=9999.00.00`); a narrower `to=9900` silently **omits all of
Chapter 99** and makes a diff look like a mass deletion of 511 headings. The
provenance assertion that caught it — checking for the Brazil headings rev_12 is
known to contain — is worth keeping in any ad-hoc revision comparison.
