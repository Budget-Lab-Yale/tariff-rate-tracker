# Forced-Labor §301 vs GTA — and the §232 displacement mechanism

**Date:** 2026-06-07 · **Branch:** theseus · **Status:** findings only, NO code changed.
**FINAL RESOLUTION (see §3b; verified against GTA's published flow-level data + our calculator code):**
We model the forced-labor §301 **largely correctly.** All structural pieces verified working: §232
displacement, 10%/12.5% tiers, Annex A, and **USMCA** (CA/MX forced-labor cut >50%: eff 0.039/0.046 vs EU
0.086 — `usmca_check.R`; applied in `06_calculate_rates.R` step-7 lines 2906/2949, prorated by utilization
share like GTA, even though the scenario *config* has no USMCA field). Both models also use the SAME §122
as the expiring tariff (IEEPA reciprocal struck by SCOTUS Feb-2026 — confirmed from GTA's post). The small
remaining +0.37 (ours) vs −0.20 (GTA) swap gap comes from **two minor statutory exemptions we lack —
CAFTA-DR textiles (~$8B) and informational materials (~$6B)** — plus our 12.5% tier; together just enough
to flip a small cut to a small hike. NOT a structural error.

> ⚠️ Two earlier claims in this doc are **RETRACTED**: (1) "our FL base is too broad / exclusions too thin"
> (artifact of raw `rate_s301fl` before §232 displacement); (2) "we're missing the USMCA exemption / $98B
> USMCA over-tax" (USMCA IS wired and firing — the $98B was a binary-threshold artifact comparing two
> *prorated* series). The §232 full-vs-partial-displacement discussion below is real but nets to a thin
> effect once USMCA and tiers are accounted for.

Two threads, investigated together because they turned out to share a mechanism:
1. Our forced-labor §301 scenario shows a tariff **increase** in July 2026, but a reputable
   external model (Global Trade Alert) shows it roughly **flat / slightly negative**.
2. While chasing (1) we interrogated how §232 stacks with the other authorities — which surfaced
   a separate, baseline-affecting issue with **fentanyl**.

Golden used throughout: **`tests/golden/bc51c0f`** (the current baseline golden — includes the pharma
§232 Sept-29 turn-on; supersedes the older `52dab78`, which predates pharma).

---

## 1. The headline numbers

Import-weighted effective US tariff rate at month-end (the `weighted_etr` column in `daily_overall.csv`):

| | June 2026 (S122 on) | July 2026 (S122 → 301) | change |
|---|---:|---:|---:|
| **Our baseline** (S122 expires, no replacement) | 11.71% | 9.16% | −2.55pp (S122 drops off) |
| **Our forced-labor scenario** (S122 → forced-labor 301) | 11.71% | 12.08% | **+0.37pp** |
| **GTA** (current → forced-labor 301) | 11.2% | 11.0% | **−0.2pp** |

GTA blog: <https://globaltradealert.org/blog/new-section-301s-hold-current-tariff-level>

Two separate discrepancies:
- **Sign of the swap.** Swapping S122 for the forced-labor 301 *raises* our rate (+0.37pp) but *lowers*
  GTA's (−0.2pp). Net gap ≈ **0.57pp**. This is the main issue.
- **Level.** Our pre-swap level (11.71%) is ~0.5pp above GTA's "current" (11.2%). Separate calibration
  question (our S122/§232/residual stack), not pursued here.

GTA's mechanism (from the article): the forced-labor §301 *substitutes* for the expiring §122; it covers
only 60 economies, and after exclusions only **~$1.167T** of imports is actually covered (they say
"three in five dollars" from the 60 economies are excluded). Tiers: **10%** on 14 economies (incl. EU,
~$595B covered), **12.5%** on 46 economies incl. China/Japan/India/Brazil (~$572B covered). Because the
covered base is so carved-down, the new 301 raises *less* than the broad §122 it replaces → slightly
negative. Their exclusions: a shared annex, **goods already under §232 (metals AND vehicles)**, USMCA
goods, civil-aircraft components, CAFTA-DR textiles, informational materials.

---

## 2. How §232 actually stacks (CONFIRMED with snapshot data)

Interrogated because of a worry: "if a wood product is §232'd *and* §122'd, do we stack both?"

**Answer: no — the opposite.** A heading-§232 program (wood, autos, semis, pharma, …) sets
`metal_share = 1.0` ("this good is 100% occupied by §232"), which drives `nonmetal_share → 0`
(`src/stacking.R:compute_nonmetal_share`). The content-split authorities are then applied to that 0%
fraction, so they **vanish**. Only **§301 is additive** and genuinely stacks on top.

Evidence — Chinese goods, golden `bc51c0f` / `snapshot_2026_rev_5`:

| Good (China) | rate_232 | rate_301 | rate_s122 | **total_additional** | naive sum if all-additive |
|---|---:|---:|---:|---:|---:|
| Wood (ch44) | 0.10 | 0.25 | 0.10 | **0.35** | 0.45 |
| Auto (ch87) | 0.25 | 0.25 | 0.10 | **0.50** | 0.60 |
| Steel (ch73) | 0.50 | 0.25 | 0.10 | **0.75** | 0.85 |
| Non-§232 good | 0 | 0.075 | 0.10 | **0.175** | 0.175 |

The S122 0.10 sits in the column but is **absent from the total** on every §232 good (total = §232 +
additive §301 only). On the **non-§232** good (bottom row, `rate_232=0`) S122 *does* apply (0.075 + 0.10).

**Mechanism, by authority class** (`stacking_policy_from_specs`, `src/stacking.R:~194-202`):
- `rate_301` → **additive** — always stacks on top of §232.
- `rate_s122`, `rate_ieepa_recip`, `rate_s301fl` (forced-labor) → **content_split**, additive_countries = ∅
  → displaced to 0 on every §232 good, **all countries incl. China**.
- `rate_ieepa_fent` (fentanyl) → **content_split**, additive_countries = **China only** → China fentanyl
  stacks on §232; **non-China fentanyl is displaced** by §232.

### Implication that corrects an earlier wrong guess
Because forced-labor §301 is content_split *exactly like S122*, it is **displaced on §232 goods the same
way** — which is precisely GTA's "§232 goods excluded from the 301" rule. **We already match GTA on the
§232 interaction.** An earlier hypothesis (that we over-tax autos / §232 goods under forced-labor)
was **WRONG** — it reasoned from the class label without noticing `metal_share=1.0` collapses the split
into a full exclusion. Retracted.

---

## 3. Suspicions (NOT yet confirmed)

### 3a. Fentanyl should NOT be displaced by §232 (baseline-affecting) — DECISION TAKEN
Per John: §232 should displace **S122** and the **forced-labor 301** (correct as-is, incl. China), but it
should **not** displace **fentanyl** — fentanyl should stack on top of §232. Today only *China* fentanyl
is additive (stacks); **non-China fentanyl (e.g. Canada/Mexico) is content-split and displaced** by §232.
That is judged wrong: fentanyl's additive set should be widened so §232 never displaces it.
- **Where:** `stacking_policy_from_specs` / `default_stacking_policy` set `rate_ieepa_fent`
  additive_countries = China only (`src/stacking.R:~196`); the displacement happens in
  `compute_stacking_contributions` via `split_active = rate_232>0 & !(country %in% additive_countries)`.
- **Effect:** changes baseline numbers wherever a §232 good from a fentanyl country (CA/MX) currently has
  its fentanyl zeroed. Will require a golden re-freeze. Magnitude unknown until measured.
- **Note:** This is the flip side of the *correct* behaviour for S122/301 — same `metal_share=1.0`
  mechanism, just the wrong authority caught in it.

### 3b. RESOLVED (empirically, with line-level decomposition): the sign flip is the EXPIRING tariff, NOT forced-labor coverage
GTA publishes a flow-level dataset (exporter × HS8, import value + every tariff component + per-exclusion
flags + 5 scenario effective rates):
- XLSX: `https://ricardo-dashboard.s3.eu-west-1.amazonaws.com/reports/forced_labour_s301/forced_labour_s301_public_dataset.xlsx`
- charts+data ZIP: same path, `..._charts_and_data.zip`
- **Persistent local copy + analysis scripts:** `~/project_pi_nrs36/jar335/gta_analysis/`
  (`analyze.R`…`analyze4.R`). XLSX sheets: README, headline_figures, tier_summary, exclusion_waterfall,
  sector_summary, economies_eff_rate, flow_level[273,086 rows].

> ⚠️ **Earlier conclusion in this section ("our FL base is too broad / exclusions too thin") is RETRACTED.**
> It was computed from the raw `rate_s301fl > 0` flag, which is the *assigned* FL rate **before §232
> stacking displacement**. Once you apply the displacement (which §2 confirmed is real), our effective FL
> coverage matches GTA closely. The per-country *swap* numbers below are unchanged and correct; only the
> diagnosis changed. Run on golden `bc51c0f` vs GTA `flow_level`, all figures **GTA-import-$ weighted** so
> weighting/basket differences are held constant.

**GTA's five scenarios (`headline_figures`, import-wtd total ETR incl. MFN):** pre-SCOTUS 15.65% →
**current 11.17%** → forced-labor (`fl_s301`) **10.97%** (= the published −0.20pp) → `fl_plus_brazil`
11.06% → **`ref_jul26_no_s301` 7.96%** (the post-expiry world: broad tariff sunsets, *nothing* replaces it).

**The swap decomposes into two independent pieces.** "FL-ADD" = forced-labor added on top of the
post-expiry world; "EXPIRING" = the broad current tariff that sunsets; **swap = FL-ADD − EXPIRING**:

| (GTA import-$ wt, pp, additional over MFN) | FL-ADD | EXPIRING | SWAP |
|---|---:|---:|---:|
| **GTA** | +3.11 | +3.22 | **−0.11** (≈ published −0.20; gap = `fl_plus_brazil` vs `fl_s301`) |
| **OURS** | +3.01 | +2.62 | **+0.39** (≈ the +0.37 headline) |
| **gap (ours − GTA)** | **−0.10** | **−0.60** | **+0.50** |

**Reading:** our forced-labor *addition* (+3.01) is **within 0.1pp of GTA's** (+3.11) — and if anything we
add slightly *less*, which on its own would push us *more negative* than GTA. The entire +0.50pp swap gap
comes from the **EXPIRING** column: our §122 sunsets only **2.62pp** of tariff where GTA's "current"
reciprocal sunsets **3.22pp**. Removing a *smaller* current tariff and adding a similar FL ⇒ our swap comes
out slightly positive; GTA removes a *bigger* one ⇒ theirs comes out slightly negative. **This is a
baseline / current-regime difference, not a forced-labor-coverage error.**

**Per-country (GTA import-$ wt, pp) — FL addition matches; the gap is all in the expiring tariff:**

| economy | FL-add GTA | FL-add OURS | expiring GTA | expiring OURS | swap GTA | swap OURS |
|---|---:|---:|---:|---:|---:|---:|
| Germany | 3.22 | 3.08 | **4.53** | **3.06** | −1.31 | +0.02 |
| France  | 4.79 | 4.66 | **7.32** | **4.63** | −2.53 | +0.03 |
| UK      | 2.84 | 2.74 | **4.68** | **2.73** | −1.83 | +0.01 |
| Italy   | 4.97 | 5.00 | **5.86** | **4.99** | −0.89 | +0.01 |
| Japan   | 3.15 | 3.08 | 3.81 | 2.43 | −0.66 | +0.64 |
| China   | 5.63 | 5.55 | 5.10 | 4.42 | +0.53 | +1.13 |
| Vietnam | 5.81 | 6.13 | 5.26 | 4.83 | +0.55 | +1.30 |
| India   | 6.08 | 6.05 | 5.19 | 4.83 | +0.89 | +1.21 |
| Brazil  | **10.99** | 3.42 | 3.83 | 2.74 | +7.16 | +0.69 |

FL-add columns are nearly identical economy-by-economy (Brazil is the lone exception — GTA's
`fl_plus_brazil` column loads a Brazil-specific action our scenario doesn't model; their headline
`fl_s301` excludes it, where Brazil would ≈ our 3.4). The **expiring** column is systematically larger in
GTA, concentrated in the **EU/UK** (Germany 4.53 vs 3.06; France 7.32 vs 4.63; UK 4.68 vs 2.73) — exactly
where the −1 to −2.5pp swaps come from.

**Root cause of the smaller expiring tariff (verified — `analyze` EU drill + GTA `recip_on_232` test):**
NOT a rate difference and NOT a trade-deal rate. The broad expiring tariff is ~10% in *both* models
(GTA implied reciprocal rate where it bites = 9–10%; our §122 = exactly 10%), and our §232 *scope* matches
GTA's (Japan 59% vs 54%, Germany 44% vs 40% of imports §232-covered). The difference is **how completely
§232 displaces the broad content-split tariff**:
- We **fully** zero §122 on §232 goods — heading-§232 sets `metal_share = 1.0` → `nonmetal_share = 0`
  (the April-2026 "full customs value" branch of `compute_nonmetal_share`), so §122 vanishes entirely.
- GTA **keeps a partial slice** on §232 goods: reciprocal still reaches **~13–32% of §232-covered import-$**
  (the non-metal content fraction) vs ~51–81% of non-§232 goods.
- Net: our **effective** §122 reaches only ~24% of Japanese / ~31% of German imports; GTA's reciprocal
  reaches 42% / 49%. So less of our broad tariff exists to be removed on sunset → our swap ticks up; GTA
  removes more → theirs drops. This single lever (partial vs full displacement of the broad tariff on a
  §232 good's non-metal content) accounts for the EU/Japan swap gap. It is a **modeling judgment**, not a
  bug: it hinges on whether §122/reciprocal legally applies to the non-metal portion of a §232 good
  (GTA: yes/partial; us: no/full). The same full-displacement choice also feeds the §3b-bis level gap.

**Coverage cross-check (effective FL, displacement applied; `analyze2.R`, GTA-import-$ wt):** classifying
each flow by GTA's own exclusion `bucket` vs our effective coverage (`rate_s301fl × (1−metal_share)` on
§232 goods) — **we agree with GTA on ~86% of import dollars** (61.6% both-exclude + 24.4% both-hit). True
over-coverage (we apply FL, GTA hard-excludes) is only **~$37B**, and the raw-flag §232 "over-cover"
collapses from $621B → **$20B** once displacement is applied. Residual genuine over-cover is small and
specific (CAFTA textiles $8B, informational $6B, ch94 furniture ~$16B, ch61 apparel ~$7B) — worth a tidy
but immaterial.

### 3b-bis. The separate LEVEL gap (our baseline runs ~1.8pp hotter on additional tariffs)
Distinct from the swap: on the **same GTA basket**, our *current* additional tariff is **11.37pp** vs GTA's
**9.59pp** (+1.78pp). That splits as **−0.60 (smaller expiring §122) + +2.29 (higher RESIDUAL stack)** —
i.e. our post-expiry §232/§301/other stack is **8.75pp vs GTA's 6.46pp**. The residual gap concentrates in
low-baseline / FTA / USMCA partners: **Mexico (ours 8.7 vs 4.2), Switzerland (8.5 vs 3.8), Singapore (6.6
vs 2.9), Ireland (4.3 vs 2.0), India (13.1 vs 9.8), Canada (6.6 vs 4.4)**; big-China/EU are close. This is
the empirical form of the doc's old "~0.5pp level" question (it's ~1.8pp on the additional-only basis;
narrower on total ETR because MFN/basket differ). Caveat: GTA's per-line `s232_rate`/`s301_rate` columns
are *applied rates on covered lines*, not ETR contributions, so a clean GTA-side per-authority attribution
is not possible from their data — the residual-gap **total** is solid; *which* of our authorities drives it
(likely §232 scope on USMCA/FTA partners, given the country pattern) needs an our-side decomposition.

### 3c. India is NOT anomalous once decomposed (earlier −8.69 was an artifact)
The earlier "India −8.69pp" came from differencing two **differently-weighted** per-country ETRs. On the
common GTA basket India's swap is **+1.21** (vs GTA +0.89) — ordinary, and its FL-add (6.05) matches GTA
(6.08). India's *current* does run hot (additional 13.1 vs GTA 9.8), but that is the §3b-bis residual/level
gap, not a forced-labor or timing anomaly. No India-specific surcharge bug is implicated by this data.

---

## 4. Suggested next steps (re-prioritised after the decomposition)
The forced-labor 301 itself is **not** the problem — our FL addition matches GTA to ≈0.1pp and our
effective coverage agrees on ~86% of import $. So the old "rebuild the exclusion set" task is **dropped**
(only a tidy of CAFTA/informational/ch94 furniture remains, ~$37B, immaterial). The real questions are
about the **baseline**:

1. **Expiring-tariff modelling (3b) — the driver of the GTA sign disagreement.** Decide whether our §122
   successor *should* sunset less tariff than GTA's "current" reciprocal, especially on the **EU/UK**
   (Germany 3.06 vs 4.53; France 4.63 vs 7.32; UK 2.73 vs 4.68). This is a policy-assumption call about
   what the post-IEEPA broad tariff is and how heavily it loads on the EU — not a code bug. If we want to
   align with GTA's framing, the §122 rate/scope on the EU is where to look. **This is the thing to put in
   front of the lab: "we and GTA agree on forced-labor; we differ on the pre-existing tariff it replaces."**
2. **Level gap (3b-bis):** our current additional runs ~1.8pp hot vs GTA on a common basket, driven by a
   higher residual §232/§301/other stack (8.75 vs 6.46) concentrated on USMCA/FTA partners (Mexico,
   Canada, Switzerland, Singapore, Ireland). Run an **our-side** per-authority decomposition for those
   countries (GTA's columns can't attribute this) — first suspect is §232 scope on USMCA/FTA goods.
3. **Fentanyl fix (3a):** still stands on its own merits — widen `rate_ieepa_fent` additive_countries so
   §232 never displaces fentanyl; measure baseline delta; re-freeze golden. (NB: in `2026_rev_9` our
   fentanyl is already 0 by the May-2026 effective date, so this may not move the June/July numbers here;
   verify the active window.)
4. India "anomaly" — **closed** (3c): an artifact of mismatched weighting; India's swap is an ordinary
   +1.21 on the common basket.

GTA data + all analysis scripts now persist at `~/project_pi_nrs36/jar335/gta_analysis/`
(`analyze.R`=raw coverage, `analyze2.R`=effective coverage, `analyze3.R`=swap decomposition,
`analyze4.R`=baseline authority decomposition; re-downloadable from the S3 URLs above). All runs use the
crosswalk census-`cty_code`↔ISO via `daily_by_country` names (99.6% of GTA import-$ matched).

## Key code references
- `src/stacking.R` — `compute_nonmetal_share` (metal_share→nonmetal_share), `compute_stacking_contributions`
  (content_split `split_active` logic), `stacking_policy_from_specs` (~194-202: per-authority class +
  additive_countries, incl. fentanyl=China-only).
- `src/06_calculate_rates.R:~2628-2647` (forced-labor rate_s301fl build), `:~2949` (USMCA CA/MX exempt).
- `config/scenarios/forced_labor/overlay.yaml` (tiers, Annex A path, boundary_overrides).
- `resources/s301fl_exempt_products.csv` (Annex A, 1,632 HTS8).
