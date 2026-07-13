# What drives the country- and product-level variation in calibrated η?

> **Source:** moved here from the `tariff-etr-adj` repo (compliance-gap η
> calibration) because the actionable items are tracker-side: the AD/CVD layer,
> the Section 232 derivative metal-share weighting, and the USMCA claiming
> share. The calibration itself stays in `tariff-etr-adj`; this note is the
> driver analysis and the to-do list for the rate tracker.

*Diagnostic note (composition-adjusted baseline, training window 2025-06 … 2026-02).*
Figures: `tariff-etr-adj/results/figures/fig_eta_by_partner.png`, `fig_eta_by_product.png`,
`fig_eta_dist_by_partner.png`. Backing numbers: `tariff-etr-adj/results/tables/eta_by_partner.csv`,
`eta_by_country.csv`, `eta_by_product.csv`.

## The one mechanism behind all the variation

Every calibrated η is

```
η = 1 − k · (collected ETR / statutory ETR)
```

where the *statutory ETR* is the tracker's modeled `rate_h2avg` value-weighted over the
cell, the *collected ETR* is Census calculated duty ÷ customs value (`cal_dut_mo / con_val_mo`),
and `k = 1.07` is the single Treasury level factor (compadj). So η is entirely a function of
one ratio, **collected ÷ statutory**:

- ratio **< 0.93** → **positive** η (collections fall short of statutory → a compliance gap)
- ratio **> 0.93** → **negative** η (collections *exceed* the modeled statutory rate)

| Partner | stat. rev. share | statutory ETR | collected ETR | ratio | η (two-way) |
|---|--:|--:|--:|--:|--:|
| Canada   | 6.6%  | 6.5%  | 3.3%  | 0.52 | **+0.51** |
| Mexico   | 11.1% | 7.4%  | 4.3%  | 0.59 | **+0.41** |
| S. Korea | 4.5%  | 13.0% | 12.1% | 0.93 | +0.00 |
| China    | 27.3% | 38.2% | 35.8% | 0.94 | −0.03 |
| ROW      | 38.7% | 8.9%  | 8.4%  | 0.95 | −0.02 |
| EU       | 5.6%  | 11.0% | 11.2% | 1.02 | −0.10 |
| Japan    | 5.2%  | 13.6% | 14.6% | 1.07 | **−0.15** |
| UK       | 1.0%  | 5.7%  | 6.3%  | 1.10 | **−0.18** |

## Why Canada & Mexico run high (collections far below statutory)

The statutory rate the tracker assigns (IEEPA fentanyl 25%, Section 232 steel/aluminum 50%,
auto 25%) applies broadly, but a large share of CA/MX trade is **not actually charged it** —
the gap is dominated by **USMCA preference claiming and sectoral carve-outs**, not evasion.
Chapter decomposition (compadj):

- **Canada — energy is essentially uncollected.** HS27 (mineral fuels, 8% of Canada's
  statutory revenue): statutory 1.75%, collected **0.015%** → ratio 0.009, η ≈ 0.99. Canada's
  single largest export category collects almost nothing.
- **Vehicles & parts (HS87)** is the biggest revenue block for both (28% CA, 47% MX):
  statutory ≈16%, collected ≈10% → ratio ≈0.64–0.67. USMCA-qualifying autos/parts enter free.
- **Machinery / electronics (HS84, HS85):** ratio 0.42–0.82 — again USMCA claiming.
- **Steel & aluminum (HS72/73/76):** statutory ≈50% (232), collected 16–36% → ratio 0.3–0.7;
  partial collection (exclusions, derivative-content rules, drawback).

Net: CA/MX collect ~50–60% of their modeled statutory amount, so η lands at +0.4 to +0.5.

## Why Japan & the UK go negative (collections exceed statutory)

These have no broad preference exemption, and their **modeled statutory rate is low** (Japan
13.6%, UK 5.7% — trade-deal "reciprocal" rates). The negative η comes from chapters where
**collected duties run above the modeled rate**, concentrated in machinery / electronics /
instruments:

- **Japan** HS84 machinery: statutory 11.0%, collected **14.9%** (ratio 1.36, η −0.46);
  HS85 electronics 1.21; HS90 instruments 1.16. Autos (HS87) sit ~at par (ratio 0.99).
- **UK** HS84: statutory 5.5%, collected **7.8%** (ratio 1.42, η −0.52); HS85 1.27; HS90 1.32.

The excess is the methodology's **"statutory-vs-declared residual"** — duties the tracker's
statutory `rate_h2avg` does not carry but Census collections do: **Section 232 derivative-content
duties (steel/aluminum embedded in machinery), antidumping/countervailing orders, MFN base
duties, and specific-duty conversions.** Because the statutory denominator is small (especially
the UK at 5.7%), even a modest absolute over-collection flips the ratio above 1 and η negative.

## Two structural reasons the contrast is so sharp

1. **A preference program on one side only.** USMCA exempts a large, high-statutory slice of
   CA/MX trade (autos, energy, machinery) → collected ≪ statutory → large positive η. Japan/UK
   have no comparable broad carve-out.
2. **Denominator size + an off-model duty residual.** The 232-derivative / AD-CVD / specific-duty
   residual exists for *every* partner, but it is small relative to CA/MX's big statutory base
   and large relative to Japan/UK's small one — so it only dominates (and turns η negative)
   where the modeled statutory rate is low.

## "But we already model USMCA claiming in the tracker — why isn't that enough?"

We do, and it is large. The tracker carries two parallel rate sets — effective `rate_*` and
full `statutory_rate_*` — plus a `usmca_eligible` flag and 232 metal-content shares. For the
USMCA partners the effective `total_rate` we read is already deeply haircut below full statutory
(unweighted over the HTS grid):

| Partner | eff. total_rate | full statutory | eff. IEEPA-fentanyl / statutory | eff/stat |
|---|--:|--:|--:|--:|
| Canada | 22.8% | 50.1% | 16.8% / 38.3% | 0.45 |
| Mexico | 18.6% | 36.1% | 12.4% / 24.4% | 0.51 |

So USMCA eligibility *and* an assumed claiming share are baked into `rate_h2avg` before we ever
calibrate. The point is that η measures what is **left over after** that haircut, and three
things still sit in that residual:

1. **Realized claiming exceeds the tracker's assumed claiming share.** The haircut above implies
   the tracker assumes ~85–90% USMCA claiming on eligible lines. Post-IEEPA, claiming on eligible
   goods is effectively near-universal — a 25% wall makes the certificate paperwork worth it for
   importers who skipped it when MFN was ~0–2%. The "assumed ~88%" vs "realized ~100%" wedge is
   pure η, and it is *additive on top of* the tracker's haircut (do not re-apply it as a USMCA
   correction — that would double-count).
2. **Channels the tracker does not model at all.** The largest is **energy**: Canada HS27 collects
   **0.015%** against a modeled 1.75% (near-total exemption). Add Chapter 98 (US goods returned /
   repairs), drawback, foreign-trade-zone deferral, and Section 232 *product* exclusions — none of
   these are in `total_rate`.
3. **232 on metals collected below the listed rate** (HS72/73/76 ratios 0.3–0.7): product
   exclusions and derivative-content rules.

Bottom line: USMCA claiming is only one of several reasons CA/MX under-collect, and even that
piece is modeled with a claiming share the data say is too conservative. η is the right place to
absorb (1)–(3) **as a composite**, but it should not be read as "the USMCA correction."

## Fixes for Japan / UK / EU (these are statutory-side coverage gaps)

A negative compliance parameter means collections exceed the modeled statutory rate — a model
*coverage* gap, not noncompliance, and not something the model should carry as a negative η. The
over-collection concentrates in HS84/85/90 (machinery, electronics, instruments). The tracker
excludes three kinds of legally-owed duty that Census/Treasury do collect:

1. **AD/CVD — the tracker has no AD/CVD field at all** (confirmed: none of the 35 snapshot
   columns is antidumping/countervailing). Japan/UK/EU carry dense AD/CVD orders exactly in
   steel, machinery, bearings, and chemicals — the over-collecting chapters. Most likely the
   single biggest driver. *Fix:* add an AD/CVD statutory layer, or strip AD/CVD out of
   `cal_dut_mo` before calibrating (cleaner — η should not absorb legally-owed AD/CVD). See the
   AD/CVD section below for why this needs an external source.
2. **Section 232 derivative-content under-capture.** Effective `rate_232` applies 232 only to an
   estimated `metal_share` of a derivative product's value; if Census collects 232 on the full
   line value for listed derivatives (or `metal_share` is too low for HS84/85), modeled <
   collected. *Fix:* reconcile the derivative metal-share weighting against the published 232
   derivative annexes for the manufactured-goods chapters.
3. **Specific-duty / `rate_other` conversions** realized at a higher ad-valorem-equivalent than
   modeled — worth checking in residual chapters (some chemicals/plastics) where 232/ADCVD don't
   explain it.

Doing (1)+(2) pulls Japan/UK/EU η back toward zero/positive and is the principled fix; it also
modestly raises CA/MX modeled statutory (they have AD/CVD and 232 too), slightly lowering their
η. A cheaper stopgap is to floor the deliverable η at 0 for the negative partners, but that masks
the gap rather than fixing it.

## AD/CVD: where it lives, and whether we can model it

- **It is in the Treasury data.** Treasury `customs_duties` (Haver `FTRU@GOVFIN`, the MTS/DTS
  customs line) is *total* duties CBP collects, including AD/CVD cash deposits alongside MFN,
  201/232/301, and IEEPA. Census `cal_dut_mo` likewise includes estimated AD/CVD. So AD/CVD is in
  **both** realized rungs of the ladder but in **neither** the tracker's statutory rate — the
  mechanical reason the negative ηs appear. (Caveat: Treasury/Census carry AD/CVD at the *deposit*
  rate set at entry; final liability is trued up at Commerce liquidation years later, so there is
  a timing wedge, but the bulk is captured.)
- **It is NOT part of the HTS rate schedule.** AD/CVD is administered by Commerce (ITA), not the
  HTS, and is keyed to a **case number** (A-… antidumping, C-… countervailing) reported under a
  **Chapter 99** provision on top of the normal Chapter 1–97 HTS-10 line. Three consequences:
  - You cannot read AD/CVD off the HTS rates; you need the Commerce **"orders in place"** database
    (case → country → covered HTS subheadings → rate; free via Access ITA / Federal Register).
  - Rates are **firm-specific** (each producer/exporter has its own margin plus an "all-others"
    rate), so an HTS×country panel can only carry an order-average — there is no single rate per
    HTS line.
  - **Scope is defined by product description**, not HTS code (codes in an order are indicative),
    so an HTS crosswalk is approximate.
- **Modeling options, given we have no AD/CVD series.** (a) Build an AD/CVD statutory layer by
  mapping active Commerce orders to HTS×country with all-others / weighted-average margins — the
  principled route, but rough because of firm-specificity and scope-by-description. (b) Pragmatic:
  treat the positive `(census − tracker_statutory)` residual for non-preference partners as an
  implied AD/CVD + 232-derivative correction and fold it into the statutory base, so η reflects
  compliance only. Either way the first input to acquire is the Commerce orders list.

## Caveat: baseline choice flips the sign for Japan/UK

Under the **announced** (fixed-2024-basket) baseline every η is higher — Japan +0.12, UK +0.11
(both positive) — because that baseline also absorbs the 2025–26 shift of the import basket
toward lower-tariff cells. The negative values are a **composition-adjusted** phenomenon: once
the basket shift is netted out, the pure statutory-vs-collected residual is what remains, and it
is negative for low-statutory-rate partners. The two baselines bracket the composition channel.

## Reading the figures

(All under `tariff-etr-adj/results/figures/`.)

- `fig_eta_by_partner` / `fig_eta_dist_by_partner`: the partner-group ranking and within-group
  chapter spread above.
- `fig_eta_vs_size` / `fig_eta_dist_ecdf`: the most extreme cell-level ηs sit in tiny-revenue
  cells; revenue-weighted, the distribution is far tighter than the raw histogram suggests.

## External corroboration for the energy η (and a time-varying caveat)

*Added 2026-07-08.* Public reporting independently confirms the near-total energy
under-collection this note attributes to USMCA claiming + carve-outs — it is
legitimate exemption behavior, not evasion or a statutory-assignment bug, so the
energy η should stay in η rather than be zeroed out of `rate_h2avg` (that would
double-count).

- **The claiming surge is real and large.** Importers did not claim USMCA on
  ~$78B of Canadian crude in 2024 (plus ~$16B of other energy entering tariff-free
  outside USMCA): when MFN was ~0 the origin paperwork wasn't worth filing. Once
  the IEEPA tariffs (10% energy tier / 25–35% general) made it worth it, oil & gas
  USMCA compliance jumped from **~25% (Jun 2024) to ~84% (Jun 2025)**, and **~99%
  of Canadian oil now enters duty-free** once all exemptions are counted (Census
  data via Reuters; *The Logic* on the "paperwork scramble"). Non-energy sectors
  lag at ~45%. Canada supplied a record ~61% of US oil imports in 2025, so this is
  a large low-collecting flow. This is exactly the "assumed ~88% vs realized ~100%"
  wedge described above — now with an external magnitude.

- **CAVEAT — claiming is TIME-VARYING, so a static claiming share mis-fits both
  ends.** The 25%→84% jump happened *within the training window* (2024→2025). A
  fixed assumed-claiming share baked into the statutory layer is therefore too
  high in early-2025 (claiming still low → tracker under-states collectible duty)
  and too low by late-2025 (claiming near-universal → tracker over-states it).
  Because η is calibrated over the pooled window, a single η per energy cell
  averages across this ramp and will be biased in any month far from the window
  mean. For the η owners: consider either (a) a month-varying energy claiming
  path, or (b) restricting the energy η calibration to the post-surge steady
  state (≈2025-H2 onward) and flagging the ramp months separately. Ties to the
  open USMCA-claim-share re-base decision (`docs/internal/eta_statutory_measurement_queue_2026-07.md`
  item 3).

- Sources: *The Logic* (oilpatch USMCA scramble); Reuters/Census via Wealth
  Professional (25%→84%→99% compliance); GHY International and PA Petroleum Assoc.
  (energy carve-out / USMCA-compliant pause); Budget Lab (Yale) and Tax Foundation
  (effective-vs-statutory framing); Equitable Growth (petroleum & coal among the
  lowest effective subsector rates); Forbes (Canada 61% of 2025 US oil imports).
