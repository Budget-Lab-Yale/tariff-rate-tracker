# Tracker findings for tariff-etr-adj — measurement requests (2026-06-10)

Statutory-side findings from the 2026-06-10 tracker sessions (commits
`d839e40` §301 exclusions, `9ba9b82` §232 conditioned routes) that need
**collections-side evaluation** in tariff-etr-adj / the eval IMDB panel.
Each item says what changed, what to measure, and what decision the
measurement gates. Items are ordered by expected payoff.

**Build-state note:** neither commit is in a full cluster build yet. The
§301 fix moves baseline numbers (144 China lines); every §232 knob is
dormant (rev_9 verified byte-identical), so current `output/actual/` and
`usmca_h2avg` snapshots reflect *pre-fix* §301 statutory rates until the
next rebuild. The eta training window (2025m5–2026m2) is fully inside the
9903.88.69 exclusion window (Jun 15 2024 → Nov 9 2026), so the §301 fix
shifts statutory rates on the affected lines for the *entire* window.

---

## 1. §301 exclusion claim shares (Phase 2 of the exclusion fix)

**What changed (tracker, `d839e40`).** Products whose footnotes reference an
in-force USTR §301 exclusion heading (9903.88.69/.70) previously paid full
§301 in the statutory panel; they are now zeroed (`coverage_share = 1.0`,
full-line). 144 HTS10 lines × China in rev_9; worked example `0304725000`
(frozen haddock) 25% → 0%, total 35% → 10%.

**Why it is an upper bound.** USTR exclusions are scoped by product
*description* and typically cover a slice of an HTS10 line. Truth is between
the old treatment (full §301, overstatement → positive-eta contribution) and
the new one (0%, likely overstatement of the correction → negative-eta
contribution on the same lines).

**Measure:** ~~per affected HTS10 × month, the share of entries filed under
9903.88.69/.70 — "the IMDB line-level ch99 filings carry this directly"~~
**CORRECTION 2026-06-11: they do not.** The public IMDB contains NO 9903
commodity records (ch99 filings are reported under the underlying HTS10;
`rate_prov` is a 2-digit aggregate), and DataWeb commodity queries on 9903
codes return nothing. Direct filing shares exist only in CBP confidential
data. The tracker now measures this itself by **realized-rate inversion**
(`claim_share = (stat_other + full_301 − cal_dut/con_val) / full_301`) —
module `tools/calibrate_s301_exclusions.R`, design + caveats in
`docs/s301_exclusion_calibration.md`. **What the eval can still add:** an
independent check of the inversion on its own IMDB panel (same `cal_dut`
field), and judgment on how much of the residual on these 144 lines is
non-exclusion compliance gap (de minimis pre-Aug-2025, AD/CVD in
collections) — that part is genuinely eval-side expertise.

**Feeds:** `coverage_share` column of
`resources/s301_exclusion_headings.csv` (per-heading, curator-promoted from
`resources/s301_exclusion_claim_shares_by_heading.csv`); per-HTS10 shares in
`resources/s301_exclusion_claim_shares.csv`. Affected lines:
`resources/s301_exclusion_lines.csv`.

## 2. Semiconductor end-use share — one division, data already in hand

**Setup.** §232 semis (25%, eff. Jan 15 2026) bite on a single HTS10 after
the interim qualifying calibration: `8471.80.4000` (GPU/AI accelerator
cards). The remaining free parameter `end_use_exemption_share`
(9903.79.03–.09 carve-outs: data centers >100 MW, R&D, startups, etc.) is
currently 0.0 = upper bound. The dominant importers are hyperscalers, who
plausibly qualify via the data-center route alone, so the old 0.3–0.5 guess
may be conservative.

**Measure:** realized effective rate on `8471.80.4000` (Taiwan primarily,
plus China) over Jan 16 – Mar 2026 collections:

    realized_rate / 0.25  =  qualifying_share × (1 − end_use_exemption_share)

With `qualifying_share = 1` on that line, the division *is* the end-use
share. No modeling judgment needed.

**Feeds:** `end_use_exemption_share` in
`policy_params.yaml::section_232_headings.semiconductors`; secondarily a
check on the interim binary `qualifying_share` itself.

## 3. `sgept_exemptions` scenario — promotion decision

**What changed (tracker, `9ba9b82`).** Four §232 annex conditioned routes
now have working share knobs, all dormant in baseline: UK 95%
qualifying-content blend (`uk_content_qualifying_share`, baseline 1.0 =
unconditional reduced rate), US-origin-metal 10% target-total route,
de-minimis (<15% metal weight), motorcycle parts. SGEPT's estimates (0.30 /
1% / 2% / 0.1%) ship as `config/scenarios/sgept_exemptions/` (build with
`TARIFF_SCENARIO=sgept_exemptions`).

**Measure:** once the scenario series is built, compare baseline vs scenario
statutory rates against realized §232 collections — most informative on (a)
UK metals lines (the UK blend is the biggest of the four: UK annex_1a
moves 25% → 42.5% under the scenario) and (b) derivative-heavy chapters
outside ch72–76 (de minimis). Whichever fits collections better wins;
promotion = copying four numbers into `policy_params.yaml`.

## 4. UK annex_1b coverage gate (tracker bug candidate, eval evidence wanted)

**Finding.** The tracker's UK reduced-rate override gates on chapters
72/73/76, but note 16(c)(vi)–(vii) annex_1b articles span other chapters —
so UK annex_1b products outside the metal chapters are charged the full 25%
where the UK deal entitles 15% (statutory overstatement, UK only,
positive-eta direction on those lines).

**Measure:** UK × annex_1b lines outside ch72/73/76 — do realized rates
cluster nearer 15% than 25%? If yes, the tracker fix (gate on the annex
CSV's `metal_type` instead of chapters) gets prioritized; it moves numbers,
so it is parity-gated and currently just a todo item.

## 5. 9903.91.04 stated expiry (Biden §301 tier) — harmlessness check

**Finding.** The new expiry scan found exactly two rate-bearing Ch99
headings past a stated expiry that the tracker deliberately retains:
`9903.91.04` (25% tier, "through December 31, 2025") and `9903.88.09`
(vestigial 2019). If the .04 products' post-2025 rate is carried by a
successor tier heading (9903.91.05+ at ≥50%), the stale row is harmless
under the tracker's max-per-HTS8 aggregation; if not, 2026 snapshots
misstate those lines.

**Measure:** realized rates on the 9903.91.04 product set in Jan–Mar 2026
collections — did the effective rate *change* at the new year? Step up ⇒
successor heading governs (harmless); step down ⇒ the expiry is real and the
tracker needs a rate-bearing expiry gate (parity-gated change).

## 6. Lower-priority gates (only if residuals point there)

- **Note 16(h)/(i) limited-quantity CA/MX steel/aluminum (9903.82.18/.19).**
  Commerce-authorized quantities (PP 10984 cl. 13), volumes unpublished. If
  CA/MX *primary* steel/aluminum lines show materially sub-statutory
  realized rates post-annex, that is the signal to model a share knob.
- **Pre-annex 9903.81.92 (US-melted steel derivatives, Mar 2025 – Apr 2026).**
  ~1%-of-derivative-steel-duties materiality. Only worth modeling if the
  2025 §232 derivative-steel residuals run negative-eta.
- **8471 annex_1b decision** (computers at 25% full-value from Apr 6 2026):
  data-gated on April+ 2026 Census collections; knobs already exist
  (zero-metal-content carve-out or an annex applicability share).

## 7. Coming soon (no action yet): specific/compound-duty exposure flags

The tracker will add a `base_rate_type` column
(`ad_valorem`/`free`/`specific_or_compound`/`other`) flowing into
`statutory_rates.csv.gz`, so eta calibration can mask the product×country
cells where the tracker models a non-ad-valorem MFN duty as 0% (the dominant
driver of the food-complex negative etas: HS04 ~47% of leaf lines exposed,
HS17 ~38%, HS21 ~31%, HS19 ~18%). Scope decision stands: the tracker flags
exposure, never converts AVEs — any AVE work is eval-side. Plan is fully
scoped in tracker `todo.md`; not yet implemented.

---

*Tracker contacts for mechanics: affected-line lists and per-heading windows
come from the parse caches (`products_<rev>.rds` ch99_refs +
`ch99_<rev>.rds` effective/expiry offsets); the §301 fix design and
validation are in tracker `todo.md` §"§301 exclusion headings" and
`docs/assumptions.md` §17–18.*
