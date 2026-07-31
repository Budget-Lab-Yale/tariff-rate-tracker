# Extending the Tariff Rate Tracker back to 2016 (and eventually 2015)

**Status document — current as of 2026-07-30.**
Audience: Budget Lab colleagues and collaborators. This is the shareable
overview: what we are building, what is already done, what is planned, and
which judgment calls a user of the historical series needs to know about.

Internal companions: the technical scoping study with the full decision record
is `docs/internal/pre2025_expansion_scoping_2026-07-28.md`; raw-data provenance
is `docs/pre2025_data_provenance.md`; per-release data coverage is
`resources/pre2025_hts_inventory.csv`.

---

## 1. What we are doing, and why it is not simply "run the model on older data"

The tracker today produces statutory U.S. tariff rates at the HTS-10 × country
level for **2025–2026**. The goal of this project is a consistent series
extending back to **2016**, with 2015 deferred (see §3).

The difficulty is not mechanical. The current product is *authority-additive on
top of a deliberately thin base layer*: it computes a column-1 MFN base rate and
then stacks Chapter 99 actions (IEEPA, §232, §301, §122) on top. That design is
sound for 2025–2026, where Chapter 99 actions of 10–50 percentage points swamp a
~2.4% MFN base. **In 2016–2024 the base layer *is* the series.** Headline
effective rates in 2016–2017 are roughly 1.4–1.6%, and the difference between
the statutory column-1 rate and what importers actually paid after claiming
preferences (USMCA/NAFTA, GSP, AGOA, KORUS, CAFTA-DR…) is on the order of
0.6–0.9pp — i.e. **40–60% of the level**. Approximations that are immaterial
today become the dominant term in the historical period.

So the work splits into three kinds of problem:

1. **Data** — do machine-readable tariff schedules even exist for these years?
2. **Structure** — can the pipeline represent a second era without disturbing
   the published 2025–2026 product?
3. **Methodology** — which assumptions silently encode "this is 2025" and must
   be re-specified for earlier years?

Everything below is organised around those three.

---

## 2. Headline decisions (locked 2026-07-28)

| # | Decision | Rationale |
|---|---|---|
| 1 | **Start at 2016**; 2015 deferred | No machine-readable HTS exists for 2015 (§3) |
| 2 | **Dual weights.** The fixed-2024-weight backfill extends the existing headline series into one continuous 2016–2026 line; a contemporaneous-weight series is published alongside as the historical view | Fixed weights isolate policy; contemporaneous weights measure history. Publishing both keeps the headline decomposable and avoids a silent methodology change |
| 3 | **Quota/TRQ split treatment.** Absolute quotas (Korea/Brazil/Argentina steel) priced at the in-quota rate with a scope note; TRQs (EU/Japan/UK 2022+, §201 solar and washers) get an `over_quota_share` utilisation knob, defaulting to in-quota until calibrated | "The statutory rate under an absolute quota" has no defensible single answer — over-quota entry was *prohibited*, so it is a quantity instrument, not a price. TRQs genuinely had over-quota trade and need a share |
| 4 | **§301 exclusions v1 = full-line zeroing**, published alongside a no-exclusion bound | The upper bound on relief; brackets the truth while deferring the hardest calibration |
| 5 | **GSP charged at column 1 from 2021-01-01** | The program lapsed 2020-12-31 and was never renewed, so those duties are final. Statutory-at-entry is also the correct ex-post answer |
| 6 | **Per-era vintages, unioned at the published parquet layer** — no monolithic panel | A single 2016–2026 panel is ~400–600M rows and exceeds the memory ceiling that has already caused failures. Per-era builds also make 2025–2026 invariance *provable* rather than merely tested |
| 7 | **Fix the column-2 defect in the current series immediately**, not as part of the backfill | It was a live error in the published product (§4.2) |

---

## 3. The data foundation: what exists, what does not

All of this was verified by direct download, not inferred from documentation.

**The USITC HTS JSON archive has three cliffs.** The published schedule is only
machine-readable back to a point, and the USITC's own static host now blocks
automated access entirely (Akamai 403), so historical editions are recoverable
only via the Internet Archive.

| Year | Releases published | Machine-readable editions obtained |
|---|---|---|
| 2016 | 2 | 1 |
| 2017 | 2 | 1 |
| 2018 | 19 | **8** |
| 2019 | 21 | 17 |
| 2020–2024 | 83 | 83 |
| **Total** | **127** | **110** |

**The consequential gap is 2018.** Eleven of nineteen 2018 editions have no
JSON, including `2018_rev_2` (effective 2018-03-23) — *the Section 232
steel/aluminium start*. The first 2018 edition we have in machine-readable form
is dated 2018-08-07, leaving a ~4.5-month blind spot directly over the launch of
the metals tariffs.

**What closes that gap** is the **USITC Annual Tariff Database** (1997–2026),
which turned out to be far more useful than expected. It is not an annual
snapshot: it carries `begin_effect_date` / `end_effective_date` per line and
emits multiple rows when a rate changes mid-year, keyed to **true statutory
effective dates**. It also carries column-2 rates and per-programme preference
columns (NAFTA CA/MX indicators, GSP with country exclusions, AGOA, KORUS,
CAFTA-DR, and the rest) — exactly the fields the base-layer problem in §1
requires. Its limits: HTS-**8** rather than HTS-10, no ad-valorem equivalents,
and schema drift between years.

We therefore have three complementary sources, and Phase 2 layers them:
the annual database as the rate-and-date spine, the HTS JSON editions for
HTS-10 structure and Chapter 99 text, and Chapter 99 PDFs (obtained for all 127
releases) for the editions with no JSON.

**Import weights** are not a constraint: Census monthly trade files are complete
and verified for 2015-01 through 2026-05, with the dutiable-value and
calculated-duty fields needed to measure preference claiming and to build
ad-valorem equivalents later.

**Why 2015 is deferred.** Zero machine-readable HTS editions exist for 2015.
Covering it means either driving the year from the HTS-8 annual database (a
different granularity from the rest of the series) or manual work from PDFs.
That is a Phase 4 decision, not a blocker for everything else.

---

## 4. What is already done

### 4.1 Phase 0 — invariance rails *(complete)*

Before adding any historical data we added a mechanism guaranteeing that a
future backfill **cannot** alter the published 2025–2026 product: a configured
series-start date that gates the revision grid, with hard stops on both build
paths and an explicit opt-out for the tools that legitimately need to see every
archive.

The proof is an A/B: a full production build from the unmodified codebase versus
one from the modified codebase, compared artifact by artifact.
**62 of 62 artifacts identical within tolerance.** The revision grid is
byte-identical; every test suite passes.

### 4.2 Phase 0b — two live defects fixed in the current series *(complete)*

Scoping surfaced a genuine error in the *published* product, on the four origins
denied normal-trade-relations treatment (Cuba, North Korea always; Russia and
Belarus since April 2022):

- **They were priced at column 1.** U.S. tariff law (General Note 3(b)) makes
  their goods dutiable at **column 2** rates, which are far higher. The model
  read only the column-1 field.
- **They were charged an IEEPA reciprocal tariff they are exempt from.** HTS
  heading 9903.01.29 exempts general-note-3(b) origins; the model charged them a
  mean 8.86% anyway — roughly half their reported total rate.

Both are fixed. The effect is confined to those four origins (verified by
fingerprinting all 13,680 partition × country cells: exactly four moved, every
other country identical). Russia's mean total rate on a representative 2025 date
goes 0.1802 → 0.3499. **The headline import-weighted ETR moves 12.2557% →
12.2574%** — these are tiny, sanctioned trade flows, so the correction matters
for per-origin rates, not for the aggregate.

A third related issue (heading 9903.82.12, which sets a different §232
derivative rate for these origins) is documented as a known gap rather than
fixed, because it requires country-aware logic that does not belong in a
base-rate change.

### 4.3 Phase 1 — data acquisition *(complete)*

Reproducible tooling plus the acquired corpus: **110 HTS JSON editions, 127
Chapter 99 PDFs, 127 Change Records, 11 annual-database years**, and
verification of the 137 months of Census weights.

Two documented traps were defended against, and the defences demonstrably
worked:

- *Truncated archive captures.* The Internet Archive truncates large captures;
  the same file exists at 645 KB, 535 KB and 78 KB. Every obtained edition was
  required to parse and carry a plausible record count — the result runs
  32,830–35,810 records per edition, so no truncated capture survived.
- *Being silently served today's data under a historical URL.* Editions were
  asserted to carry era-appropriate content. The clearest evidence it worked:
  **the §301 List 3 rate reads 10% in 6 editions and 25% in 97** — the
  2019-05-10 step is visible in the data itself.

Zero validation failures. The 19 releases with no JSON are recorded explicitly,
so the gaps are documented rather than silent.

---

## 5. What is planned

### Phase 2 — the 2018–2024 statutory build

The substantive modelling work. The pipeline's authority classification is
already generic enough to recognise the 2018-era headings (§301 lists, §232
metals, §201 safeguards), but the *rates* are currently frozen at their 2025
values and must gain a time dimension:

- **§301 China** — rates are hard-coded at their February-2020 values, so every
  date before then is wrong. List 3 (10% → 25%, May 2019) and List 4A
  (15% → 7.5%, February 2020) need dated schedules. The 2018–2021 exclusion
  timeline is the largest single body of work.
- **§232 metals** — country exemptions currently have expiry dates but no
  *start* dates, so the model would treat Canada, Mexico and the EU as exempt in
  2018–2019 when they were not. Quota and TRQ regimes need the treatment agreed
  in decision 3.
- **§201 safeguards** — the solar rate is a single scalar at its final
  step-down value and needs the annual schedule; the washing-machine programme
  (2018–2023) is currently not modelled at all.
- **§301 aircraft** (EU/UK, 2019–2021) needs its own non-China branch.
- **Miscellaneous Tariff Bill** — one cycle falls in the window (October 2018 to
  December 2020, never renewed); the provisions persist in later schedules as
  expired, so membership tests would wrongly credit relief after 2020.
- **Revision dating** — roughly 180 new revision rows, each requiring the
  publication-date-versus-effective-date judgement the tracker already applies.
  The annual database's true effective dates reduce this materially.

### Phase 3 — 2016–2017 and the weights spine

- Extend the code-identity crosswalk backwards. This is a correctness issue, not
  bookkeeping: **two full HS nomenclature revisions land inside the window
  (HS2017 and HS2022)**, changing roughly 3,000–4,000 HTS-10 codes. Without a
  concordance, codes silently drop out of the weighted denominator and produce a
  spurious level break at exactly 2017-01-01 and 2022-01-01 that would *look
  like policy*.
- Rebuild preference-claiming shares annually from contemporaneous Census
  calculated-duty data, and re-key preference eligibility for the NAFTA era.
  (Today the model identifies USMCA eligibility by a programme code introduced
  in July 2020; run against a 2018 schedule it silently finds none, which would
  hand Canada and Mexico — about a quarter of imports — full MFN rates.)
- Produce the dual-weight outputs of decision 2.

### Phase 4 — calibration and refinement

Ad-valorem equivalents for specific duties (the prerequisite for column-2 and
agricultural magnitudes to be fully meaningful); §301 exclusion claim shares
measured from entry data; TRQ fill shares; an entry-coverage sidecar so that
statutory-versus-collected comparisons mean the same thing across the boundary;
and the 2015 decision.

---

## 6. What users of the historical series will need to know

These are the assumptions most likely to affect interpretation. All are being
documented in the repository's standing assumptions and deviations registries.

| Item | Why it matters |
|---|---|
| **Preference claiming is measured, not modelled line-by-line** | The single largest driver of the 2016–2019 level. We estimate claim shares from observed duty collections rather than reconstructing eligibility rules per programme |
| **HS nomenclature breaks** | 2017 and 2022 restructure the code universe; the concordance is what prevents a spurious level break |
| **§301 exclusions, v1** | Full-line zeroing is an *upper bound* on relief, published with the opposite bound. Expect the China rate in 2019–2020 to be revised when calibrated |
| **Specific duties read as zero** | The tracker does not convert per-unit duties to ad-valorem equivalents. This understates agriculture, footwear, and column-2 origins until Phase 4 |
| **Quotas are not tariffs** | Absolute quotas are priced at the in-quota rate; the restriction is real but is a quantity instrument |
| **Antidumping/countervailing duties are excluded** | Consistent with current practice, but AD/CVD was a much larger share of duties collected in 2016–2017, so the statutory series will sit well below any collections benchmark in those years |
| **Retroactivity is not modelled** | Rates change on the date the measure takes legal effect going forward; retroactive refund windows are noted, not simulated |

---

## 7. Sequencing and current position

| Phase | Content | Status |
|---|---|---|
| 0 | Invariance rails | **Complete** — A/B parity 62/62 |
| 0b | Column-2 and GN 3(b) fixes to the current series | **Complete** — scope-verified |
| 1 | Data acquisition | **Complete** — 110 editions, 0 validation failures |
| 2 | 2018–2024 statutory build | Next |
| 3 | 2016–2017, weights and concordance spine | Planned |
| 4 | Calibration, AVEs, 2015 | Planned |

Phases 0, 0b and 1 are implemented and pushed as three reviewable changesets.
None of them alters any published number except the four-origin correction in
0b, which is documented above and immaterial to the headline.

The ordering is deliberate: the invariance guarantee lands before any historical
data, the data is acquired and validated before any modelling depends on it, and
the era with the best data coverage (2018–2024) is built before the era with the
worst (2016–2017).
