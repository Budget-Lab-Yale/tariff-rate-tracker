# Proposal: calibrating the §232 annex-era exemption routes (note 16)

**Status: measurement module BUILT + first run 2026-07-08** (same day; no
ENGINE changes): `tools/calibrate_s232_annex_routes.R` (30 unit tests green),
no_232 counterfactuals via `scripts/submit_no232_annex_snapshots.sh` (Slurm
17417038). First-measurement headline (May 2026, $39.8B annex trade):
route-explainable mass is much smaller than issue #13's gap suggests —
`us_origin` signature 11.9% of value; *strong* exit evidence (realized ≈ a
materially positive without-232 total) only **1.5%**; the big near-zero bucket
(42.6%) sits on ITA/§122-exempt lines where `T_exit ≈ 0`, so routes are NOT
distinguishable from non-entry/η there (§7's guard binding exactly as
designed). Outputs: `resources/s232_annex_route_shares.csv` +
`output/diagnostics/s232_annex_routes_monthly.csv`. Awaiting curator review
(§8 sequencing) before any promotion.

Originally written 2026-07-08 as a proposal, in response to
issue #13 (ch84/85 realized/statutory ≈ 0.48, bimodal). Companion to the
issue-#13 comment: the annex-era full-value application is the letter of the
proclamation (Annex I-A/I-B "shall apply to the full value",
`annexes_text.txt:1-3, 203-205`), so the actionable statutory gap is not
metal-content proration — it is the **note-16 exemption routes the tracker
currently models at `aggregate_share = 0`** (deviations registry item P3).

Guiding principles, in order:

1. **Hew to the statutory language.** Every fix below is anchored to a specific
   ch99 heading and note-16 subdivision, quoted verbatim. A route is modeled
   the way the note scopes it (product-characteristic vs. certification vs.
   end-use), not the way that is convenient to estimate.
2. **USMCA treatment is the guide when calibration is required** (registry U1:
   per-HTS10 × country utilization shares, deliberate vintage choice, explicit
   zero-vs-missing joins; A§3). Where a route is a whole-line entitlement with
   near-costless take-up, the measured share reflects *legal scope* rather than
   behavior, and the calibrated tracker remains a statutory-rate tracker — the
   same framing as the §301 exclusion claim shares (U3,
   `docs/s301_exclusion_calibration.md` "Interpretation note").
3. **Measurement reality**: per-heading ch99 filings are NOT publicly
   observable (verified 2026-06-11, s301 calibration doc §"Measurement
   reality"; IMDB carries only the underlying HTS10). Any route share must be
   recovered by **realized-rate inversion** (the U3 Phase-2 method) or from
   route-specific external data — never assumed observable.

---

## 1. The statutory route inventory (new U.S. note 16, eff. 2026-04-06)

Annex IV of the April 2026 proclamation (`docs/s232/annexes_text.txt:723-988`)
rewrote U.S. note 16. The charging headings and the exemption/reduction routes
are **mutually exclusive** (note 16(a): "an imported article will be subject to
no more than one of these headings"). Verified against the parsed rev_5 HTS
(`data/timeseries/ch99_2026_rev_5.rds`):

| Heading | Note 16 | Duty | Role | Tracker today |
|---|---|---|---|---|
| 9903.82.02 | (c)(i)–(v) | +50% full value | charging: annex_1a | modeled (step 5c) |
| 9903.82.09 | (c)(vi)–(viii) | +25% full value | charging: annex_1b | modeled (step 5c) |
| 9903.82.10/.11 | (f), (c)(ix)–(x) | 15% target-total / no change | charging: annex_3 | modeled (floor_post_mfn) |
| **9903.82.01** | heading text | **No change (0)** | **exemption: zero metal content** | dormant knob, share = 0 |
| **9903.82.03** | (c) proviso | **No change (0)** | **exemption: metal weight < 15%** | dormant knob, share = 0 |
| **9903.82.06** | (e), (c)(ii)(iv)(vi)(vii) | +10% | **reduction: ≥95% US-origin metal** | dormant knob, share = 0 |
| **9903.82.07/.08** | (e), (c)(ix)–(x) | 10% target-total / no change | **reduction: ≥95% US-origin metal** | dormant knob, share = 0 |
| **9903.82.13** | (g) | **No change (0)** | **exemption: motorcycle parts end-use** | dormant knob, share = 0 |
| 9903.82.04/.05 | (d) | +25% / +15% | reduction: UK 95% melted-and-poured | `uk_content_qualifying_share = 1.0` (registry U5) |
| 9903.82.12 | gen. note 3(b) | +25% | column-2 countries | out of scope here |
| 9903.82.14–.17 | | 50/10/25/25% | Russia | modeled (country_surcharges) |

Not exemption routes, and deliberately **out of scope** for this proposal
(they load onto the same realized-vs-statutory residual and must be
sequenced in the decomposition, §6): entry-date timing around 2026-04-06,
chapter 98 / FTZ channels, Annex II scope questions (registry S3, separate
collections audit), Proclamation 11032 / annex_1c framework routes (own
config block), and genuine noncompliance (η — belongs downstream).

---

## 2. Route A — 9903.82.01, zero metal content

**Statutory language** (heading text, rev_5 parse):

> "Articles provided for in subdivision (c) of U.S. note 16 to this subchapter
> **that do not contain any aluminum, steel, or copper**" — Duty: *No change*.

**What kind of condition this is.** A physical characteristic of the imported
article — not a certification, not an end-use. Within an HTS10 line, some
articles contain covered metal and some do not; the line-level share is a
fixed property of the product mix, in the same family as the §301 exclusion
scope shares ("aggregation of heterogeneous statutory rates to the tracker's
HTS10 resolution limit"). Claiming it at entry is near-costless, so measured
take-up ≈ legal scope, and calibrating it keeps the tracker statutory.

**Proposed treatment.** Per-HTS10 share `z01(hts10)` = fraction of the line's
customs value that is articles containing no covered metal. Jointly identified
with Route B (§3) — both produce exactly 232 = 0 — so **measure them as one
combined zero-route share `z0 = z01 + z03`** (inversion cannot split them, and
for rate purposes the split is irrelevant; see §3 for the diagnostic prior
that can split them if ever needed).

## 3. Route B — 9903.82.03, covered-metal weight below 15%

**Statutory language** (note 16(c) proviso + heading text):

> "For articles classified in the listed provisions that are **not in chapters
> 72, 73, 74 or 76**, headings 9903.82.02 and 9903.82.04–9903.82.17 **only
> apply where the weight of the applicable metal is at least 15 percent of the
> weight of the imported article.** … If an article is classified in a
> provision that is present on multiple lists, use the aggregate weight of the
> listed metals."

> 9903.82.03: "…articles where the weight of the applicable metal is less than
> 15 percent of the weight of the imported article" — Duty: *No change*.

**What kind of condition this is.** Also a physical characteristic, but a
**weight** test, not a value test — the BEA I-O *value* shares we hold
(`resources/metal_content_shares_bea_hs10.csv`) are not the statutory
quantity and must not be used as the share directly. Like Route A it is a
scope condition with near-costless claiming, so measured share ≈ legal scope.
This is the route most likely to carry the bulk of issue #13's 32%
zero-realized mass: ch84/85 machinery with plastic/electronic content below
15% covered-metal weight is common, and the config's `de_minimis_weight`
knob already anticipates exactly this scope (`applies_to: [annex_1b,
annex_3]`, `excludes_chapters: ['72','73','74','76']`).

**Proposed treatment (A+B jointly).**

- **Measure** a combined zero-route share `z0(hts10 × country)` by
  realized-rate inversion on annex-classified lines, mirroring
  `tools/calibrate_s301_exclusions.R`. The inversion must respect the
  **stacking branch move**: an article that legally exits §232 via .01/.03
  does not simply drop `rate_232` — it lands in the *without-232* stacking
  branch where the IEEPA reciprocal (and fentanyl/S122 where applicable)
  applies on full value. The Taiwan note-35(c) aircraft carve-out is the
  in-repo precedent for exactly this branch move (`rate_232 → 0` "dropping
  them into the 'without 232' stacking branch so the IEEPA reciprocal applies
  on full value", policy_params.yaml §aircraft exemption). Per line-month:

      realized ≈ stat_other + (1 − z0 − u)·r_232_annex + z0·r_no232_branch + u·r_usorigin

  where `r_no232_branch` is the tracker's own without-232 statutory total for
  that cell and `u` is Route C's share (§4). Zero-route mass is identified by
  realized clustering at `r_no232_branch` (≈ MFN + reciprocal, often ≈ 0 for
  exempt-country/exempt-program cells); Route C by clustering at the 10%
  target-total signature. Report raw (unclipped) shares; curator review
  before promotion — never auto-written (U3 discipline).
- **Apply** as an expected-value blend at the same point the dormant knobs sit
  today (06_calculate_rates.R step 5c exemption block, :2934-3011), upgraded
  from a scalar `aggregate_share` to a per-HTS10(× country) share table, and
  — this is the statutory-fidelity fix the current knob lacks — blending the
  **two stacking branches**, not just scaling `rate_232`:

      E[total] = (1 − z0)·total_with_232 + z0·total_without_232

  `statutory_rate_232` keeps the printed annex rate (upper bound preserved);
  `rate_232` and the stacked `total_rate` become expected values, exactly how
  USMCA (U1) and MFN-exemption (U2) shares already enter the build. Publish
  `z0` (and Route C's `u`) as snapshot columns so downstream (η) can see which
  part of the gap the tracker has already absorbed.
- **Optional diagnostic split of z0 into .01 vs .03**: BEA value-share ≈ 0
  lines are the .01-heavy tail. Diagnostic only; never enters rates.

## 4. Route C — 9903.82.06/.07/.08, ≥95% US-origin metal

**Statutory language** (note 16(e)):

> "…at least 95 percent of the aluminum content of the article must be
> composed of aluminum that was **smelted and cast in the United States**
> [(c)(ii),(vi),(ix)] … at least 95 percent of the steel content … **melted
> and poured in the United States** [(c)(iv),(vii),(x)] … at least 95 percent
> of the copper content … smelt and cast in the United States [(c)(viii)].
> These requirements are **cumulative**…"

Duty: 9903.82.06 = +10% (instead of +25/50%) for (c)(ii),(iv),(vi),(vii);
9903.82.07/.08 = **10% target-total** for (c)(ix)–(x) ("the sum of the column
1 duty rate and the additional ad valorem rate … will be 10 percent") — the
same `floor_post_mfn` semantics the config already encodes for this knob.

**What kind of condition this is — and why it is NOT Route A/B.** A
**supply-chain certification**, not a product characteristic: qualifying
requires documented US smelt/cast (or melt/pour) provenance, mirror-image of
the UK 95% test in note 16(d) (registry U5) and of the Russia smelt-and-cast
clause (A§18). Certification is costly, so take-up < legal scope — this route
is **behavioral in the USMCA sense**, and the USMCA guide applies literally:
a per-country utilization share, defaulting to 0 where there is no evidence
of use, concentrated where US-origin metal plausibly flows through foreign
fabrication (CA/MX supply chains first; cf. the USMCA-steel and
`us_content_exempt_cap` machinery for annex_1c).

**Proposed treatment.**

- **Measure** `u(country [, hts10])` from the same inversion as §3 — Route C
  is separable from Routes A/B because it produces a *distinct nonzero* rate
  signature: realized clustering at the 10% (target-total) level, i.e. the
  realized/statutory ≈ 0.25–0.50 bucket that holds 18% of issue #13's ch84/85
  value (10/25 = 0.4). Fit per country first; per-line only where mass
  supports it.
- **Apply** with the existing `us_origin_metal` blend, which already has the
  correct statutory shape (`06_calculate_rates.R:2974-2992`:
  `u·pmin(rate, floor_post_mfn(10%)) + (1−u)·rate`) — the fix is calibrating
  `u` per country instead of one dormant economy-wide scalar. No stacking
  branch move: the article stays a §232 article at the reduced rate.
- Registry: new U-item; SGEPT's 0.01 becomes the scenario overlay, not the
  actual default.

## 5. Route D — 9903.82.13, motorcycle parts

**Statutory language** (note 16(g) + Annex II note):

> "Heading 9903.82.13 applies to articles that otherwise meet the criteria of
> subdivisions (c)(vi)–(viii) that are motorcycle parts classifiable in
> chapter 84, 85 or 87 **for use in the manufacturing of motorcycles in the
> United States**." — Duty: *No change*. (Annex II adds: "…when imported
> **exclusively** for use in the manufacturing of motorcycles.")

**What kind of condition this is — and why it gets a different approach than
Route C.** An **end-use certification**: eligibility depends on what the
importer will do with the article, not on what the article is. No HTS10 line
is "a motorcycle-parts line" — any (c)(vi)–(viii) article in ch84/85/87 could
qualify for one importer and not the next. Consequences:

- **Inversion cannot identify it.** Its zero-duty signature is
  indistinguishable from Routes A/B on the same lines, and its magnitude is
  far below the noise floor (US motorcycle manufacturing is a handful of
  firms; SGEPT's estimate is 0.001).
- **Per-line shares would be meaningless** — the statutory scope is
  importer-conditional, so a line-level share is not a stable legal quantity.

**Proposed treatment.** Keep the **aggregate expected-value knob** — for this
route, unlike A–C, the scalar IS the statutically faithful resolution — and
calibrate it **top-down from industry data**: US motorcycle assembly input
demand (BEA I-O motorcycle manufacturing intermediates × import share) as a
ceiling on route value, divided by total annex-1b ch84/85/87 import value.
Expected order: 10⁻³ or below. If the ceiling confirms that, document it in
the registry (P3 successor) and leave the knob at the calibrated small value
or 0 with an explicit "bounded immaterial" note — an honest dormancy, which
is different from today's uncalibrated dormancy.

## 6. Route E — 9903.82.04/.05 (UK content test) — already tracked

Note 16(d) (≥95% UK melted-and-poured / smelted-or-cast). Same certification
family as Route C; already has its own knob (`uk_content_qualifying_share`,
currently 1.0 = everyone passes — the opposite polarity of the other routes)
and registry item U5 with SGEPT's 0.30. Fold its calibration into the Route C
inversion run (UK cells: realized clustering at 25/15% vs 50/25%) rather than
running a separate exercise. No new mechanism needed.

---

## 7. Decomposition order and validation

Issue #13's evidence for ch84/85 (May 2026): 32% of derivative value at
realized ≈ 0, 18% at 0.25–0.50 × statutory, 19% at full. Proposed reading,
to be tested by the calibration run, in this order:

1. Timing/coverage screens first (placebos): pre-2026-04 months must show
   `z0 ≈ 0` on the same lines under the *pre-annex* statutory series (which
   already carries B1 metal-content scaling); Annex II lines must show no
   §232 mass at all.
2. `z0` (Routes A+B) absorbs most of the near-zero bucket **only** on cells
   where the without-232 branch total is itself near zero — where the
   without-232 branch is materially positive (reciprocal-paying countries),
   near-zero realized is *not* attributable to A/B and stays in the residual.
   This guard is what keeps the calibration from laundering η into statute.
3. Route C (`u`) takes the 10%-signature mass, UK cells fold into Route E.
4. Remainder = timing + ch98/FTZ + η — handed to the eval/adj layer with the
   published `z0`/`u` columns so it is never double-counted.

Acceptance checks: reproduce issue #13's value-weighted realized/statutory on
the calibrated series (target: ratio ≈ 1 on the statutory-explainable mass);
raw-share distributions reviewed for <0 / >1 mass; unit tests on the
inversion algebra incl. the branch move (extend
`tests/test_s301_exclusion_calibration.R` pattern).

## 8. Implementation plan (mirrors the U3 module layout)

| Piece | File (proposed) |
|---|---|
| Affected-lines mapping | reuse `resources/s232_annex_products.csv` + `classify_s232_annex()` — no new builder |
| Measurement | `tools/calibrate_s232_annex_routes.R` (IMDB + snapshot join + 3-component inversion of §3–4) |
| Per-line shares | `resources/s232_annex_route_shares.csv` (`hts10, country, z0, u, months, raw stats`) |
| Monthly detail | `output/diagnostics/s232_annex_routes_monthly.csv` |
| Application | extend the step-5c exemption block (:2934-3011): scalar knobs → per-line table; add the without-232 **branch blend** for `z0` (Taiwan-carve-out mechanics, generalized to expected-value weights) |
| Published columns | `s232_route_z0`, `s232_route_usorigin` on annex-era snapshots |
| Registry | P3 → split into calibrated U-items (one per route); F6 partially resolved |
| Tests | inversion units; branch-blend stacking test; placebo (pre-April) test |

Sequencing: measurement script + first run first (no engine changes — outputs
are reviewable CSVs); engine application only after curator review of the
first measurement, as with U3 Phase 2. Weighted IMDB work runs on Slurm
(interactive 5 GB cap); the eval IMDB cache at
`../tariff-etr-eval/data/imdb/raw` avoids re-downloading.

## 9. What this proposal explicitly does NOT do

- Does **not** re-introduce metal-content proration of annex-era statutory
  rates (issue #13 suggested fix 1) — contradicts the "full value" text.
- Does **not** touch pre-2026-04-06 snapshots (B1 already calibrated; the
  regime is correct there).
- Does **not** change `statutory_rate_232` — the printed annex rate stays,
  routes enter as expected-value utilization like U1/U2/U3.
- Does **not** attribute the full 32% zero-realized mass to statute — the §7
  branch-total guard bounds what the routes may absorb; the rest remains η's
  problem, now with the tracker's absorbed share published and visible.
