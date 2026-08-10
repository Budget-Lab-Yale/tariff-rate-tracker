# Review: Section 232 polysilicon proclamation (signed 2026-08-06)

**Reviewed 2026-08-07.** Source: [Adjusting Imports of Polysilicon and its
Derivatives into the United States](https://www.whitehouse.gov/presidential-actions/2026/08/adjusting-imports-of-polysilicon-and-its-derivatives-into-the-united-states/),
plus [Annex I](https://www.whitehouse.gov/wp-content/uploads/2026/08/ANNEX-I.pdf)
and [Annex II](https://www.whitehouse.gov/wp-content/uploads/2026/08/Annex-II.pdf).
Not yet in any HTS revision (rev_15 of 2026-08-03 predates it).

## Verdict

A new Section 232 action, **effective 2026-12-04**, creating U.S. note 42 and
headings **9903.45.30–9903.45.36**. It has two layers: a conventional ad valorem
tariff, and a **minimum import price (MIP) enforced as a conditional specific
duty** ($/kg and $/watt).

**The ad valorem layer is straightforward to model. The MIP layer is not
representable in the tracker as it stands** — it is a per-unit duty, and it is
contingent on importer documentation rather than on any product or origin
attribute.

Two pre-existing problems surface because of where this action lands:

1. **Heading-range collision.** `9903.45.30–.36` classify as **`section_201`**,
   because Solar 201 owns the whole `9903.40–45` range.
2. **The Solar 201 safeguard expired 2026-02-06, and the tracker has no date
   gate for it** — so the published series still charges 14.5% on solar cells
   and modules for every date after that. The new action lands on the *same*
   HTS10 lines. **This is a live error worth more than the polysilicon action
   itself** (~$2.4B/yr, ~0.08pp of weighted ETR) and should be fixed first.

Exposure is **$16.8B of 2024 imports (0.54% of the panel)**, concentrated
almost entirely in solar modules.

## Structure

### Ad valorem layer — 9903.45.30–.32

| Heading | Rate as written | Scope | Semantics |
|---|---|---|---|
| `.30` | applicable subheading **+ 15%** | ingots/wafers, solar cells, solar modules — all origins except `.31`/`.32` | **Additive.** Note 42 has no cap clause for `.30` |
| `.31` | **15%** | product of **Liechtenstein, Japan, South Korea, Switzerland, Taiwan, or an EU member** | **Total capped at 15%** — note 42(c): where column 1 < 15%, col-1 + additional "will total 15 percent" |
| `.32` | applicable subheading **+ 10%** | product of the **United Kingdom** | **Additive**, no cap clause |

The `.30` vs `.31` asymmetry is the thing to get right: the general 15% stacks
on top of MFN, while the framework-partner 15% is a ceiling on the total. This
is *not* the pharma pattern — note 40(d) caps the default heading too, note 42
does not.

Note also that **raw polysilicon (2804.61.0000) appears in no ad valorem
heading.** It is in Annex I and in `.33` only. Raw polysilicon gets the MIP and
no 15%.

### MIP layer — 9903.45.33–.36

| Heading | HTS10 scope | Specific duty |
|---|---|---|
| `.33` | `2804.61.0000` (silicon ≥ 99.99%) | **+ $21 / kg** |
| `.34` | `3818.00.0020`, `.0040`, `.0045`, `.0050`, `.0091` | **+ $100 / kg** |
| `.35` | `8541.42.00` (cells) | **+ $0.22 / watt** |
| `.36` | `8541.43.00` (modules) | **+ $0.38 / watt** |

These are **not** duties most importers pay. Per note 42(a), `.33`–`.36`
**do not apply** where the entered value meets or exceeds the specific rate
**and** one of three resale conditions holds:

> 1. the product will not be resold in the US and any downstream product will
>    be sold at or above the specific rate for that downstream product;
> 2. the product will be resold in the US at or above the specific rate; or
> 3. the product will be resold under fixed terms in a time-limited contract
>    entered into before **August 6, 2026**.

They apply "if the importer … fails to submit documentation concerning the
resale of those products to CBP upon entry, or if the importer submits such
documentation but CBP is required to adjust the customs duty assessed."

So the MIP is a **price-floor enforcement backstop**. Modelling it as an
unconditional specific duty would badly overstate both the rate and the
revenue. The honest treatment is a compliance-share parameter — the same shape
as the semiconductor Note 39 `semi_qualifying_shares.csv` gate, which likewise
approximates a condition the HTS cannot express.

### Stacking

Note 42(b) mirrors note 40(b): duties are collected **in addition to** FTA and
preference special rates, chapter 98 claims stay eligible, **no chapter 99
lower-rate or duty-free claim is allowed**, and AD/CVD continues.

**Annex II modifies no other note.** Unlike every other §232 sectoral action —
steel, aluminium, copper, autos, wood, MHD vehicles, semiconductors, and now
pharma — polysilicon is **not** added to the §232-overlap exclusion lists in
note 2(v), note 2(aa)(v), note 50(a)(vi) or note 52(f). There is no
displacement of any other authority. Nothing in the annex grants USMCA relief
either; Canada and Mexico appear only as Trade Agreement Partners eligible for
manufacturing drawback, which is not an exemption.

By 2026-12-04 the stack these lines actually sit in is MFN + Section 201 (if
still live) + this action + §301 where applicable + AD/CVD. IEEPA is
invalidated and §122 expired 2026-07-23, so there is no blanket layer for it to
interact with.

## Exposure

2024 imports, from `data/weights/hs10_by_country_gtap_2024_con.rds`
(panel total $3,123.8B):

| Layer | HTS10s | 2024 imports | Share of panel |
|---|---|---|---|
| Solar **modules** `8541.43` (`.36`) | 2 | **$14.81B** | 0.474% |
| Solar **cells** `8541.42` (`.35`) | 2 | $1.83B | 0.059% |
| **Polysilicon** `2804.61` (`.33`) | 1 | $0.13B | 0.004% |
| Ingots/**wafers** `3818.00` (`.34`) | **0 present** | **$0.00B** | — |
| **Total** | | **$16.77B** | **0.537%** |

Modules are 88% of the exposure. The wafer row is the problem — see Finding 3.

## Findings

### Finding 1 — the new headings classify as Section 201

`classify_authority()` routes `middle >= 40 && middle <= 45` to `section_201`
(`src/model/rate_schema.R:344`). Verified:

```
9903.45.30 -> section_201      9903.45.21 -> section_201   (real Solar 201)
9903.45.31 -> section_201      9903.79.01 -> section_232   (semis, for contrast)
9903.45.33 -> section_201
```

A §232 action would land in the Section 201 bucket — wrong authority label in
`daily_by_authority`, and wrong bucket for any generic ch99 attach path.

The rate *extraction* is safe: `extract_section201_rates()` restricts itself to
`9903.45.21–.29` (`05_parse_policy_params.R:1275`), so it will not read `$21/kg`
as a solar safeguard rate. And no chapter 1–97 product line footnote-references
`9903.45` in rev_15 — the only four references are self-references inside
Chapter 99. So this is latent, not live.

The fix follows the Section 338 precedent already in the file: match on heading
*segments* (`parts[2] == 45 && parts[3] %in% 30:36` → `section_232`) **before**
the broader `9903.40–45` Section 201 bucket. The `section_338` block at
`rate_schema.R:298` is the model, and its docstring already explains why
segment-matching beats string-matching here.

### Finding 2 — specific duties are not representable

`parse_rate()` collapses every non-ad-valorem rate to `NA` with a
`specific_or_compound` flag (`src/core/helpers.R:93,118`). The tracker is an ad
valorem model throughout: `base_rate` coalesces a missing MFN rate to 0
(`rate_schema.R:104`).

`$21/kg`, `$100/kg`, `$0.22/W` and `$0.38/W` therefore cannot be expressed
directly. Converting them to ad valorem equivalents needs **quantity**, and the
watt-denominated ones need **capacity**, which is not in the HTS10 value panel
at all. The existing precedent is
`src/experimental/load_adcvd_layer.R`, which carries an
"ad-valorem-equivalent ALL-OTHERS" rate — the same trick, and the same caveats.

Combined with the conditionality in note 42(a), the recommendation is: **model
the ad valorem layer now, and represent the MIP as an explicit, documented
zero** with a named share parameter for later calibration. A zero here is
defensible (compliant importers pay nothing) and honest; an uncalibrated
per-unit duty converted through a guessed quantity is neither.

### Finding 3 — the wafer lines don't exist in the weight concordance

Annex I and heading `.34` cite five statistical suffixes under `3818.00.00`.
The rev_15 schedule has them:

```
3818.00.00.20  Polycrystalline silicon wafers, doped
3818.00.00.40  Round (circular) shaped, per statistical note 2 to ch. 38
3818.00.00.45  Pseudo-square or rectangular, per statistical note 3
3818.00.00.50  Other
3818.00.00.91  Other
```

The 2024 GTAP weight panel has **only the old suffixes**:

```
3818000090   $1.39B
3818000010   $0.14B
```

None of the five cited lines carry any weight. As written, the polysilicon layer
would attach to the wafer lines and move **nothing**, silently dropping $1.39B
of exposure — the annual **$100/kg** heading, the largest per-unit rate in the
action, applied to a base of zero.

This is the 484(f) versioned-identity problem the repo already has machinery
for: commit `15646c6` added the 484(f) weight mapper, and the rev_11 changelog
entry flags exactly this failure mode ("GTAP weights concordance (176/179 new
codes absent)"). The `3818.00.00` split needs a concordance entry mapping the
retired `.90` (and `.10`) weight onto the new suffixes before this action can be
weighted. Worth checking whether the split is already in
`data/484f/source_manifest.csv`.

### Finding 4 — Solar 201 overlaps these lines and may have expired

Three of the four solar HTS10s in Annex I are **already** in
`resources/s201_solar_products.csv`:

| HTS10 | In Solar 201 list | In polysilicon Annex I |
|---|---|---|
| `8541420010` | yes (`9903.45.25`) | yes |
| `8541430010` | yes (`9903.45.21`) | yes |
| `8541430080` | yes (`9903.45.21`) | yes |
| `8541420080` | **no** | yes |

Two things follow.

**(a) The polysilicon action is broader on cells** — it picks up `8541420080`,
which Solar 201 does not cover.

**(b) `apply_section201()` has no date gate — and the safeguard has expired.**
It applies `section_201.solar_rate: 0.145` flat across the entire series
wherever the product and country match (`06_calculate_rates.R:1243–1268`); a
grep for any date, expiry, or window handling on `section_201` returns nothing.
The config's own comment already says the rate schedule runs out:

> `- 2025-02-07 → 2026-02-07 (Year 8 of extension)`
> `- update annually based on USTR notice`

Year 8 was the last year available. Proclamation 9693 imposed the safeguard from
2018-02-07 for four years, Proclamation 10454 extended it four more, and
§203(e)(1)(B) of the Trade Act caps a safeguard at **eight years total**.

**The CSPV safeguard terminated 2026-02-06.** USITC instituted investigation
**TA-201-075** expressly to evaluate the effectiveness of the relief action
"which terminated on February 6, 2026" ([91 FR, 2026-03-17](https://www.federalregister.gov/documents/2026/03/17/2026-05170/crystalline-silicon-photovoltaic-cells-whether-or-not-partially-or-fully-assembled-into-other)).

**The repo's own archives have carried the evidence since February, and the
model cannot read it.** USITC stamped a compiler's note onto all five Solar 201
headings, and the shaded-provision legend in the Chapter 99 PDF now reads "the
shaded areas indicate the provision has expired":

> `9903.45.22`  Other **[Compiler's note: This subheading and its related note,
> U.S. note 18 to this subchapter, have expired. See 87 Fed. Reg. 7357.]**

The stamp first appears in **`2026_rev_4`** (published 2026-02-24) and is absent
from `2026_rev_3` (2026-02-12) — bracketing it to exactly the weeks after the
2026-02-06 termination. It is present in every archive since, including rev_15.
As of rev_15 there is **no live CSPV provision anywhere in Chapter 99**.

Two mechanisms independently fail to notice:

- `extract_section_201_rates()` sets `has_s201 = TRUE` on the mere *presence* of
  `9903.45.21–.29`, and they are still present as shaded historical entries. The
  rate then comes from config, not the schedule, by design — the override exists
  precisely because the HTS shows the stale 30% Year-1 rate.
- `filter_active_ch99()` drops entries whose `expiry_date_offset` precedes the
  revision date, but `extract_expiry_date_offset()` only matches
  `(through|on or before|before) <Month> <D>, <YYYY>`. The compiler's note
  carries **no date at all**, so the parser returns `NA` and the entry stays
  active. Verified against the literal string:

  ```
  extract_expiry_date_offset("… have expired. See 87 Fed. Reg. 7357.") -> NA
  ```

The FR citation in the note is to 87 FR (2022), which reads as stale but is not:
it points at the proclamation that set note 18's terminal date, and the *stamp*
is what is new.

So this is **a live overstatement in the published series**, not a
forward-looking concern, and it is independent of the polysilicon action:

- Every snapshot dated **after 2026-02-06** charges 14.5% on
  `8541420010` / `8541430010` / `8541430080` where it should charge zero.
- Those three lines carry **$16.6B** of 2024 imports, so the phantom duty is on
  the order of **$2.4B/yr**, and roughly **0.08pp of weighted ETR**
  (14.5% × 0.533% of the panel) from 2026-02-07 onward.
- Separately, the **rate itself looks off by 0.5pp**: secondary sources put Year
  8 (2025-02-07 → 2026-02-06) at **14%**, not the configured 14.5%. Worth
  confirming against the USTR step-down notice while fixing the gate, though it
  is moot for any date after expiry.

The fix is a date gate on `section_201` — `expiry_date: '2026-02-06'`, following
the `section_122` `expiry_date` / `policy_expiry_date` pattern already in the
config — plus a boundary mint at 2026-02-07 so the drop lands in the series.
This is the highest-value item in this document.

## What to do

Nothing is required before 2026-12-04, and no HTS revision carries these
headings yet, so there is no ingest to do. In priority order:

1. **Date-gate `apply_section201()` at the confirmed 2026-02-06 expiry**
   (Finding 4b), with a boundary mint at 2026-02-07. This is a live series
   error on $16.6B — the largest number in this document — and the only item
   here that is already wrong rather than merely forthcoming.
2. **Add the `classify_authority()` segment rule** for `9903.45.30–.36` →
   `section_232` (Finding 1). Cheap, and it prevents a silent misclassification
   whenever USITC codifies the headings.
3. **Add the 3818.00.00 484(f) concordance mapping** (Finding 3), or the wafer
   layer is guaranteed to be weightless.
4. **Model the ad valorem layer** as a new `section_232_headings.polysilicon`
   program on the pharma/Brazil/s338 pattern — hand-fed from the proclamation
   with a date gate at `2026-12-04`, since no HTS archive carries the headings.
   It needs a shape the existing config vocabulary does not quite have: an
   **additive** default (`.30`, +15%) alongside a **`target_total`** tier
   (`.31`, 15% all-in) and a second additive tier (`.32`, UK +10%). The pharma
   block's `max(country_rate, target_total − base_rate)` resolves the wrong way
   for an additive default, so this is not a copy-paste of that block.
   `usmca: none` — no USMCA relief in the annex.
   Scope: `.30`/`.31`/`.32` cover the wafer + cell + module lines but **not**
   `2804.61.0000`.
5. **Record the MIP as a documented zero** with a named compliance share
   (Finding 2), plus a deviations-registry entry stating that the specific-duty
   backstop is out of scope and why.
6. **Watch for the codifying HTS revision.** When it lands, reconcile the
   published `.30`/`.31`/`.32` rates against the config the way rev_13 was
   reconciled — and expect the note 42 product enumeration to be the
   authoritative scope, since Annex I explicitly says its descriptions are
   "provided for informational purposes only."

## Out of scope for the tracker

Recorded so they are not mistaken for gaps:

- **Manufacturing drawback** under 19 U.S.C. 1313(a)–(b) for Trade Agreement
  Partners (UK, EU, Japan, South Korea, Switzerland, Liechtenstein, Mexico,
  Canada, and future framework partners), conditional on no AD/CVD order and
  polysilicon content sourced entirely from a partner.
- **Foreign trade zones** — admission only under privileged foreign status
  (19 C.F.R. 146.41).
- **Onshoring tariff offsets** on production equipment and inputs for approved
  facility investments, with construction start by 2029-01-20.
- **Substantially-equivalent-MIP arrangements**: the Secretary and USTR may
  alter applicability for partners that adopt their own MIP. A future
  proclamation, not a current rate.
