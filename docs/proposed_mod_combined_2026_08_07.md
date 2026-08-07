# Combined implementation plan: HTS 2026 revisions 13–15, pharmaceutical corrections, Solar 201 expiry, and polysilicon Section 232

**Status: IMPLEMENTATION IN PROGRESS — core policy/configuration changes are in
the working tree; full Slurm builds and publication review remain.**

Implementation checkpoint (2026-08-07):

- complete: source preservation, revision 13/15 manifest integration, durable
  Section 301 exclusion scope, Solar 201 expiry, UK pharmaceutical correction,
  polysilicon classification/scope/country tiers/date gate, MIP disclosure
  resources, and 484(f) transfer verification;
- locally validated: preflight, authority-adapter tests, boundary discovery,
  focused Solar/pharmaceutical/polysilicon tests, and wafer-value conservation;
- remaining before publication: the full clean rate suite (excluding separately
  identified stale-snapshot failures), source downloader/diff tooling, Slurm
  snapshot builds, vintage comparisons, and documentation/changelog completion.

This plan reconciles:

- `docs/proposed_mod_chatgpt_2026_08_07.md`; and
- `docs/proposed_mod_claude_2026_08_07.md`.

The combined plan keeps the strongest parts of each review, resolves their disagreements explicitly, and separates the existing-series correction from the future polysilicon authority.

**Revised 2026-08-07 after verification against the repository, the USITC release
API, and live fetches of the disputed source URLs.** Where the two source
proposals disagreed on a checkable fact, this document now records what was
actually observed rather than which review argued more confidently. See §0 for
the verification log and §5 for the corrections made.

## 0. Source acquisition — DONE 2026-08-07, staged for implementation

The revision 15 window was open and has been used. Everything below is on disk
and has now been force-staged because it is gitignored by pattern
(`.gitignore:18-19` for archives, `:22` for change records).

| File | Size | Route |
|---|---|---|
| `data/hts_archives/hts_2026_rev_15.json.gz` | 665,718 B | `exportList`, while rev_15 was `status: current` |
| `data/hts_change_record/Chapter 99_2026HTSRev14.pdf` | 13,957,198 B | reststop `file` endpoint |
| `data/hts_change_record/Change Record_2026HTSRev13.pdf` | 266,685 B | reststop `file` endpoint |
| `data/hts_change_record/Change Record_2026HTSRev14.pdf` | 105,770 B | reststop `file` endpoint |
| `data/hts_change_record/Change Record_2026HTSRev15.pdf` | 93,423 B | reststop `file` endpoint |

Provenance for the archive — raw JSON `sha256
452e050c957fbb4a032096fac188dfdf3dee89cd5b4fec86757d88ffad3f6c01`, gzip
`6d25c48cdd5a3e8777d7588dd2a266b5af6b87b7e6ea736a7d696d8487d80b04`, retrieved
2026-08-07 from
`https://hts.usitc.gov/reststop/exportList?from=0101.21.00&to=9999.00.00&format=JSON&styles=true`
after confirming `releaseList` still reported rev_15 as current.

Validation performed on the archive, all passing: 35,788 records; 622 `9903.*`
entries; key set byte-identical to rev_12 (including the upstream
`addiitionalDuties` misspelling); +111 HTS numbers versus rev_12 with **zero
removals**, all in Chapter 99 — the 101 forced-labor headings from revision 13
plus the 10 pharmaceutical headings from revision 14; gzip round-trips.

**Revision 14 is partially recovered.** Its JSON is still unobtainable, but the
reststop file endpoint serves a release-specific `Chapter 99_2026HTSRev14.pdf`
(805 pages), which carries the whole pharmaceutical action. This is better than
the change record alone and should be treated as the revision 14 primary source.

**Trap, confirmed empirically:** `exportList?release=2026HTSRev14&…` returns
HTTP 200 and a payload byte-identical to the rev_15 download. The `release`
parameter is silently ignored. This is exactly the failure mode
`src/pipeline/02_download_hts.R:47-50` warns about, and it would save
current-release data under an archived revision's filename without any error.
Never pass `release` to `exportList` and never trust that it was honored.

### 0.1 Verification log

| Claim under dispute | Verified result |
|---|---|
| Static archive host serves revision 13/14/15 JSON | **No.** All three return Akamai `Access Denied` (403) with a browser user-agent. Corroborated in-repo by `.gitignore:16-17` and `src/pipeline/02_download_hts.R:10-12,41-47`, which record the block for **all** revisions since June 2026 and note that `exportList` serves only the current release |
| Revision 14 JSON is obtainable | **No** — but see §0: its Chapter 99 PDF is, which covers the entire pharmaceutical action. Record the JSON gap; do not re-attempt the static host |
| Revision 13 JSON needs downloading | **No.** Already committed on `origin/feat/ingest-2026-rev13` at `441043a` (`hts_2026_rev_13.json.gz`, 692,254 bytes, force-added). Cherry-pick, do not fetch |
| Revision 15 JSON is obtainable | **Was, and was taken.** Archived 2026-08-07; see §0 for hashes |
| `exportList` honors a `release` parameter | **No.** Returns 200 and the current release regardless. Silent wrong-data hazard |
| Revision 13 schedule date | **2026-07-28** per the release API and the branch's own `revision_dates.csv` row. Not 07-27 |
| Repository tip | `config/revision_dates.csv` ends at `2026_rev_12`; 46 archives on disk before this work, none past rev_12; no change record past rev_11 |
| Reststop change-record endpoint serves archived releases | **Yes.** Revisions 13, 14 and 15 all retrieved |
| Revision 15's only substantive change is `9903.04.63` | **Yes.** Its change record lists exactly one item — `9903.04.63 | Modified (rates of duty) | July 31, 2026 | Notice` |
| UK pharmaceutical heading rate | **Confirmed from both sides.** Revision 14's Chapter 99 PDF reads `9903.04.63 … the applicable subheading + 10%`; the revision 15 JSON reads `The duty provided in the applicable subheading +0%`. Also `9903.04.60 = 100%`, `9903.04.62 = 15%` |
| Solar 201 headings carry an expiry stamp | **Yes, in the schedule itself.** `9903.45.21` and `.22` in the rev_15 JSON carry the compiler's note "This subheading and its related note, U.S. note 18 to this subchapter, have expired" |
| Polysilicon headings exist in the HTS | **No.** No `9903.45.3x` in revision 15, as both reviews said. Must be hand-fed from the proclamation |
| Section 301 patented-pharma exclusion covers `.60-.66` only | **Yes.** Revision 14's Chapter 99 PDF, note item (1): "patented pharmaceutical articles provided for in headings 9903.04.60, 9903.04.61, 9903.04.62, 9903.04.63, 9903.04.64, 9903.04.65 and 9903.04.66" — `.67-.69` absent, as the Claude review recorded |
| `section_201` has any date handling | **No.** `config/policy_params.yaml:74-75` is `solar_rate: 0.145` and nothing else |
| Pharma config matches the reviews | **Yes.** `config/policy_params.yaml:194-205`: `effective_date: '2026-09-29'`, `country_rates.CTY_UK: 0.10`, `target_total.CTY_UK: 0` |
| Revisions 13–15 are rate-neutral apart from `9903.04.63` | **Not established — see §0.2.** A large, undocumented endnote deletion at revision 13 is unaccounted for |

### 0.2 M0 — Unexplained collapse of Chapter 99 cross-reference endnotes at revision 13

**This was not in either source proposal. It is a blocking question for the
revision 13 merge, and on the evidence available it is the largest unresolved
item in this document.**

It surfaced from a size check: revision 15's raw JSON is 905 KB *smaller* than
revision 12's despite carrying 111 more records. Every string field grew. The
shrinkage is entirely in `footnotes`, and it is confined to one class:

| footnote class | rev_12 | rev_13 | change |
|---|---:|---:|---|
| `columns:['general']`, type `endnote` | 10,411 | **127** | **−98.8%** |
| `columns:['stat','units']`, type `footnote` | 3,035 | 3,134 | +99 |
| `columns:['other']`, type `endnote` | 680 | 680 | 0 |
| `columns:['desc']`, type `endnote` | 365 | 219 | −146 |
| `columns:['units']`, type `endnote` | 118 | 118 | 0 |

Every other class is stable. The casualties are the `"See 9903.88.15."`-style
China Section 301 cross-references: **9,384 Chapter 1–97 lines lost their
footnotes**, with their `general` rates unchanged. Lines in Chapters 1–97 whose
footnotes reference `9903` fall from 11,243 to 771.

Across the 2026 chain, the break is sharp and sits at revision 13:

| | rev_9 | rev_10 | rev_11 | rev_12 | rev_13 | rev_15 |
|---|---:|---:|---:|---:|---:|---:|
| footnote objects | 14,993 | 15,000 | 14,996 | 15,005 | **4,664** | 4,674 |
| ch1-97 refs to 9903 | 10,567 | 10,567 | 10,563 | 10,563 | **766** | 766 |

**This is not an artifact of how revision 15 was fetched.** The revision 13
archive already committed on `origin/feat/ingest-2026-rev13` — obtained
independently, by someone else, when revision 13 was current — shows the identical
profile, and the new revision 15 download matches it. Whatever happened, happened
upstream between 2026-07-21 and 2026-07-28.

**Why it matters.** These footnotes are load-bearing, not decoration.
`extract_chapter99_refs()` exists specifically to parse them
(`src/core/helpers.R:216-229`, docstring: "Looks for references like
'See 9903.88.15' in footnotes"); it feeds `ch99_refs` at
`src/pipeline/04_parse_products.R:146`, which seeds the footnote-rate join in
`calculate_rates_fast()` (`src/pipeline/06_calculate_rates.R:18,45`). Section 232
is explicitly *not* linked this way (`05_parse_policy_params.R:692`), which is
what makes the footnote path matter disproportionately for Section 301.

**Why nobody caught it.** The change record cannot show it — revision 15's states
outright that it "does not include staged rates, **endnotes** or minor
nonsubstantive format adjustments," and neither the revision 13 nor revision 14
change record mentions footnotes at all. The revision 13 review's rate-neutrality
finding rests on heading reconciliation and general-rate diffs, neither of which
would see an endnote deletion. A record-count or Chapter 1–97 rate diff will not
see it either.

**What the code trace establishes.** Base China Section 301 attachment is not
lost: `build_s301_tiers()` reads `resources/s301_product_lists.csv` and applies
the resulting HTS8 tiers independently of product footnotes. The vulnerable path
is narrower but still material: `apply_section301()` derives the product scope of
active USTR exclusion headings from the current snapshot's `products$ch99_refs`.
Those exclusions can therefore disappear when the export stops carrying the
cross-reference endnotes even though the base duty remains.

The repository already contains the durable input needed to fix this:
`resources/s301_exclusion_lines.csv` maps exclusion headings to affected HTS10
lines across the pre-collapse revisions. Promote it to the calculation-side
scope source; keep snapshot footnotes as a diagnostic rather than the source of
truth. Two readings of the upstream deletion remain open, but neither should
control computed exclusions after that migration:

- USITC genuinely removed the cross-reference endnotes from the schedule, in which
  case the tracker must stop depending on them; or
- the export serializer stopped emitting that class, in which case revisions 13–15
  as held are *incomplete snapshots* and ingesting them would silently drop
  attachment for ~9,400 product lines.

**Required before revision 13 merges — this gates Phase 2:**

1. Add `resources/s301_exclusion_lines.csv` as the configured, durable
   heading-to-HTS10 scope source for `apply_section301()`. Continue taking active
   heading windows and coverage shares from the current Chapter 99 data and the
   exclusion registry.
2. Prove that base China Section 301 tiers and exclusion-adjusted rates are
   unchanged across the revision 12 to revision 13 ingest, apart from separately
   documented policy changes.
3. Distinguish the two readings. The archived Chapter 1–97 PDFs from the reststop
   file endpoint render the schedule as published and are independent of the JSON
   serializer — compare a sample of affected lines (`0101.21.00`, `0101.29.00`,
   `0101.30.00.00` all lost `"See 9903.88.15."`) between the revision 12 and
   revision 15 chapter PDFs.
4. Whatever the outcome, add the assertion in §3 test 3 so a silent endnote
   deletion can never again pass as a rate-neutral ingest.

## 1. Evaluation of the two proposals

### Findings that agree

Both proposals support the following conclusions:

1. Revision 14 adds the pharmaceutical Section 232 headings; revision 15 corrects heading `9903.04.63` for the United Kingdom to `+0%`.
2. `section_232_headings.pharma.country_rates.CTY_UK` must therefore change from `0.10` to `0.0`.
3. The polysilicon action takes effect on **2026-12-04** and requires a new Section 232 program rather than reuse of an unrelated authority.
4. The polysilicon country treatments have different semantics:
   - most origins: additive 15 percent;
   - the EU, Japan, Korea, Taiwan, Switzerland, and Liechtenstein: total-duty floor of 15 percent;
   - United Kingdom: additive 10 percent.
5. Raw polysilicon is covered only by the minimum-import-price mechanism; wafers, cells, and modules are covered by both the ad valorem and MIP mechanisms.
6. The MIP must not be represented by an arbitrary flat percentage.
7. The new authority must be date-gated, tested at the 2026-12-04 boundary, and kept inactive before that date.

**Decided, not agreed.** Incorporating revisions 13, 14, and 15 in chronological
order is this document's decision, not a shared finding. Only the ChatGPT review
proposed ingesting revision 13; the Claude review treated it as arriving with the
`feat/ingest-2026-rev13` merge and scoped itself to revisions 14 and 15. The
repository state settles it — `config/revision_dates.csv` ends at `2026_rev_12`,
so all three intervals are missing from `master`.

### Stronger elements of the ChatGPT proposal

The ChatGPT proposal is stronger on:

- integrating the already-developed revision 13 work before revisions 14 and 15, and identifying the exact commits to apply;
- preserving raw HTS snapshots, hashes, and reproducible provenance;
- enumerating the complete polysilicon HTS10 scope and MIP amounts;
- distinguishing the additive MIP component from the ad valorem heading component; and
- defining detailed snapshot, country-tier, boundary, stacking, and parity tests.

Two weaknesses. First, the quantity-based MIP AVE is too ambitious for the
initial release unless reliable kilograms and watts can be joined to the model's
value weights and the importer-documentation conditions can be represented.

Second, and more seriously, **its sourcing does not hold up.** The three static
JSON URLs it lists under "Sources reviewed" all return Akamai `Access Denied`
(403), and the repository has documented that block for all revisions since June
2026 (§0.1). Its exact record counts — 35,779 / 35,789 records, 612 / 622 Chapter
99 entries, "byte-identical" Chapters 1-97 — therefore have no demonstrable
provenance. They may well be right, but they must be **re-derived from archives
this repository actually holds** before they are used, and they must not be
promoted to build-acceptance gates on their current footing (see §3.1).

### Stronger elements of the Claude proposal

The Claude proposal is stronger on:

- identifying the expired Solar Section 201 safeguard as a live, material error that should be corrected before adding the polysilicon authority;
- identifying the open pharmaceutical treatment for 2026-07-31 through 2026-09-28;
- warning that the pharmaceutical `target_total` implementation cannot be copied directly because the polysilicon default tier is additive;
- identifying the 2026 484(f) mapping problem for the new `3818.00.00xx` wafer suffixes;
- identifying `classify_authority()` gaps for `9903.04.6x` and `9903.45.30-.36`;
- recommending HTML-normalized HTS diffs and archived change-record downloads;
- separating the Solar 201 correction into its own attributable vintage;
- **correctly diagnosing the source-availability problem** — the static host block, the `exportList` current-release-only limitation, and the resulting permanent loss of revision 14, all confirmed in §0.1; and
- reconciling what is *already correct* as well as what is broken (§3.0), which prevents wasted or actively harmful rework.

Its principal weaknesses are its description of the working tree and the proposal
to stop permanently at a zero MIP contribution. On the first: it states that the
archive tip is revision 13, that the revision 15 archive and the revision 14/15
change records are already on disk, and that preflight is green with 89 archives.
None of that describes this tree — the tip is revision 12, there are 46 archives,
and no change record past revision 11. Every code and config anchor it cites does
check out, but its filesystem claims should not be relied on. On the second: a
zero MIP contribution is a defensible initial baseline, but should not end the
attempt to develop a validated quantity-based diagnostic.

### Resolved decisions

1. **Revision archives:** route by source, per the §0.1 verification. Revision 13
   is cherry-picked from `origin/feat/ingest-2026-rev13` (`441043a`), where its
   archive is already committed. Revision 15 is fetched from `exportList` *now*,
   while it is still the current release (§0). Revision 14 is **permanently
   unobtainable as JSON** — do not add a real `2026_rev_14` build row that the
   archive-driven pipeline will silently skip. Preserve its Chapter 99 PDF and
   change record, record the JSON gap, represent the already-modeled July 31
   policy changes with the existing `bnd_2026-07-31` synthetic boundary, and use
   revision 15 as the next real HTS snapshot. Document that July 31 through
   August 2 uses revision 13 schedule data plus separately modeled policy changes.
2. **Solar 201:** treat the 2026-02-06 termination as a separate, highest-priority correction. Do not combine its rate effect with the future polysilicon vintage.
3. **Pharmaceutical interim window:** retain the current 2026-09-29 model start for now, but document the explicit assumption that the pre-September 29 trade is treated as Secretary-identified. Do not impose a guessed 100 percent rate or guessed exemption share.
4. **MIP baseline:** initially model the ad valorem component and set the MIP contribution explicitly to zero under a documented-compliance assumption. Develop quantity-based MIP AVEs separately and activate them only after data and formula validation.
5. **Polysilicon rate design:** implement additive default and UK tiers plus a framework-partner total-duty floor. Do not reuse the pharma resolver without extending its semantics and tests.

## 2. Combined implementation sequence

### Phase 0 — Freeze evidence and confirm inputs

Acquisition is **done** (§0); what remains here is staging, provenance, and the
diff work. Note that §0.2 gates Phase 2, so resolve it before ingesting.

1. Record the current branch, commit, and working-tree state before implementation.
2. Preserve official source URLs, retrieval timestamps, release identifiers, file hashes, and change records for revisions 13–15. The revision 15 hashes are in §0.
3. Stage what §0 fetched, and account for the three releases by their **respective**
   routes — they are not interchangeable, and treating them as one download step is
   what the earlier draft of this plan got wrong:
   - `hts_2026_rev_13.json.gz` — **cherry-pick** from `origin/feat/ingest-2026-rev13` (`441043a`); already committed there, no download exists;
   - `2026_rev_14` — JSON **unobtainable**; do not add a real build row. Record
     the gap, use `Chapter 99_2026HTSRev14.pdf` as the primary source, and rely
     on the existing July 31 synthetic policy boundary;
   - `hts_2026_rev_15.json.gz` — **on disk, unstaged**; `git add -f`.
4. Add a repeatable downloader for the USITC REST file endpoint
   (`https://hts.usitc.gov/reststop/file?release=<ID>&filename=<NAME>`), which
   serves **archived** releases and is the only route to per-revision attribution
   once a release has been missed. Verified working for revisions 13–15 with
   `filename=Change%20Record`, and for `filename=Chapter%2099`, which returns a
   release-specific PDF of the chapter. The chapter route generalizes — it is the
   fallback whenever a revision's JSON is gone, and §0.2 step 2 depends on it.
   Do **not** pass `release` to `exportList`; it is silently ignored (§0).
5. Normalize HTML tags and whitespace only in the comparison layer. Preserve the raw schedule text in the archives.
6. Reproduce the revision diffs and confirm:
   - revision 13 supplies the expected new Chapter 99 material;
   - revision 14 adds the pharmaceutical headings and related text; and
   - revision 15 changes the UK pharmaceutical rate to zero, with no unrelated Chapter 1–97 rate change.
7. **Diff the footnote payload, not just records and rates.** The §0.2 endnote
   collapse is invisible to every check in item 6. Any revision diff from here on
   must report footnote counts by `(columns, type)` class alongside record and
   rate deltas.

### Phase 1 — Correct the expired Solar Section 201 safeguard

Publish this as its own vintage before the polysilicon work.

1. Add a last-active date of `2026-02-06` for the Solar 201 program.
2. Prefer enforcing the date through the authority specification's `active$until` path if that path is honored by rate calculation as well as boundary discovery.
3. `active$until` is now enforced in `apply_section201()`. The first dead day,
   `2026-02-07`, is already a real revision edge when policy dates are applied,
   so no duplicate synthetic boundary is minted.
4. Confirm the correct final-year rate from a primary USTR or presidential source before changing the existing `0.145` value. Treat the 14 versus 14.5 percent question separately from the undisputed expiry.
5. Acceptance criteria:
   - pre-2026-02-07 partitions are unchanged, absent a separately approved final-year-rate correction;
   - covered Solar 201 products receive zero Section 201 rate from 2026-02-07; and
   - the build contains the real 2026-02-07 partition.

### Phase 2 — Integrate HTS revisions 13, 14, and 15

**Gated on §0.2.** Do not merge revision 13 until the endnote question is
resolved. Its ingest is currently characterized as rate-neutral, and that
characterization was reached by checks that cannot see the deletion.

1. Review the revision 13 branch by commit and cherry-pick only the verified ingest, parser, test, and documentation changes required on current `master`.
2. Add real revision rows only where an archive exists:
   - `2026_rev_13` — 2026-07-28 (release API `releaseStartDate`, matching the row already written on the ingest branch; **not** 07-27, and not the 07-29 the archive display has shown);
   - `2026_rev_15` — 2026-08-03.
3. Do not add `2026_rev_14` to `revision_dates.csv`. Preserve its PDF sources and
   document that `bnd_2026-07-31`, owned by revision 13, represents the July 31
   policy state until the revision 15 archive becomes active on August 3.
4. Leave `policy_effective_date` empty for revision 15; use its schedule effective date for snapshot ownership.
5. Force-add the official archives and change records where repository ignore rules require it.
6. Run preflight after each added real snapshot and assert that every configured
   real revision has an archive, so future missing rows cannot be silently skipped.
7. Acceptance criteria:
   - real partitions at July 28 and August 3, plus the existing synthetic July 31 policy partition;
   - all earlier partitions remain identical;
   - the revision 14 Chapter 99 PDF and revision 15 archive both confirm the new
     pharmaceutical headings (there is no revision 14 JSON partition); and
   - revision 15 is rate-neutral relative to revision 14 after the UK correction, except where the corrected UK treatment is intentionally sourced from the schedule.

### Phase 3 — Correct and harden the pharmaceutical program

**What is already correct — do not rework it.** Two independent reconciliations
from the Claude review constrain everything in this phase, and both should be
restated in any implementation note so that working machinery is not "fixed":

- **Product scope reconciles exactly.** `resources/s232_pharma_products.csv`
  (131 HTS10s) against the U.S. note 40(c) enumeration (131 HTS10s): nothing in
  the note is missing from the file, nothing in the file is absent from the note.
  Zero mismatches.
- **Rate structure already matches, non-obviously.** Note 40(d)/(f) states a
  net-of-MFN *total*, and the calculator's `target_total` arm
  (`06_calculate_rates.R:399`) implements exactly that:
  `rate_232 = max(country_rate, max(target_total - base_rate, 0)) * (1 - generic_share) * (1 - exempt_share)`.
  The existing `target_total` tiers therefore reproduce headings `.60` and `.62`
  correctly, with `generic_share` / `exempt_share` standing in for `.67` / `.66`.
- **The Section 301 patented-pharma exclusion was already modeled, and correctly.**
  Revision 14 added patented pharmaceuticals as item (8) to the §232-overlap
  exclusions in notes 50(a)(vi) and 52(f); the repo implements this from the FR
  notice's Annex I Part B (`config/policy_params.yaml:867`
  `patented_pharma_exempt_date: '2026-07-31'`, masked at
  `06_calculate_rates.R:1085`) and gets the subtle part right — §301 relief starts
  **07-31** even though the §232 duty starts **09-29**. Revision 14 confirms this
  work rather than requiring any change. Verify the existing path against the
  revision 14 text; do not introduce a duplicate mechanism.

Then:

1. Change `CTY_UK` from `0.10` to `0.0` (`config/policy_params.yaml:197`); retain its zero `target_total` entry at `:205`.
2. Add a regression test asserting zero pharmaceutical Section 232 duty for the UK.
3. Add a regression test asserting the 2026-07-31 Brazil and forced-labor patented-pharmaceutical exclusions **remain active** and remain dated 07-31, independent of the 09-29 §232 activation. This guards behavior that is currently correct and unprotected.
4. Document the 2026-07-31 through 2026-09-28 Secretary-identified-company assumption in `docs/statutory_deviations.md`, recording the note-40(c) universe (roughly $160B of 2024 imports) so the assumption's magnitude is visible rather than implied.
5. Add a `classify_authority()` rule for `9903.04.60-.69` before relying on Chapter 99 as the pharmaceutical rate authority; `9903.04.6x` currently routes to `other` because there is no rule for `middle == 4`.
6. Prefer schedule-sourced rates with config as a tested fallback once classification is correct. This would make future schedule corrections such as revision 15 observable automatically — it would have caught the UK rate change without anyone reading the change record, which is the strongest argument for it.
7. Record, but do not silently solve, the residual Section 301 exclusion issue: headings `.60-.66` receive the exclusion, while `.67-.69` do not. Note the direction — here the approximation **removes** a §301 duty rather than adding a §232 one.

### Phase 4 — Add polysilicon authority infrastructure and scope

1. Add a dedicated `polysilicon` Section 232 program and product resource.
2. Add a segment-specific classification rule mapping `9903.45.30-.36` to Section 232 before the broad `9903.40-.45` Section 201 rule.
3. Represent the ad valorem tiers explicitly:
   - default: additive `0.15`;
   - EU/Japan/Korea/Taiwan/Switzerland/Liechtenstein: `max(0.15 - base_rate, 0)`;
   - United Kingdom: additive `0.10`.
4. Do not create a general USMCA exemption and do not displace other tariff authorities unless a specific statutory overlap rule requires it.
5. Include the exact scope:
   - raw polysilicon: `2804.61.0000` — MIP only;
   - wafers: `3818.00.0020`, `.0040`, `.0045`, `.0050`, `.0091`;
   - cells: `8541.42.0010`, `.0080`;
   - modules: `8541.43.0010`, `.0080`.
6. Register the program and source on all snapshots, but activate it only when `effective_date >= 2026-12-04`.
7. **Mint the 2026-12-04 boundary explicitly.** Date-gating alone does not create
   a partition at the activation date, and §3 tests the series "immediately before
   and on 2026-12-04" — without a mint there may be no partition there to test.
   Either add `2026-12-04` to `boundary_overrides` in `config/policy_params.yaml`
   (the route the pharma §232 September 29 gate already uses; see the comment at
   `:951-954`), or set the authority spec's `active$from` and confirm
   `collect_schedule_boundaries()` mints from it. This is the same mechanism
   question Phase 1 raises for 2026-02-07 and should be answered once, for both.

### Phase 5 — Verify the existing wafer weight mapping

1. The required transfer chain is already present in
   `resources/hts10_484f_transfers.csv`: legacy `3818.00.0090` transfers partly
   to `.0020` and `.0095` on 2025-01-01; `.0095` then transfers to `.0040`,
   `.0045`, `.0050`, and `.0091` on 2026-07-01.
2. Keep the existing versioned 484(f) mapper and its documented even-fallback
   rule for the 2026 one-to-many split; do not add a polysilicon-specific remap.
3. The implementation check against the revision 15 panel maps approximately
   $925.4 million of the 2024 wafer value into the five covered successor lines
   and conserves the full input value.
4. Retain automated transfer-edge, nonzero covered-value, and value-conservation
   checks before publishing the polysilicon vintage.

### Phase 6 — Represent the minimum-import-price mechanism in two stages

The statutory amounts are:

| Scope | Amount |
|---|---:|
| Raw polysilicon | $21/kg |
| Wafers | $100/kg |
| Cells | $0.22/watt |
| Modules | $0.38/watt |

**Stage A — publishable baseline**

1. Do not add a permanent zero-valued rate column. Model the ad valorem program
   and add a machine-readable marker such as `mip_model: documented_zero` only
   if useful for disclosure.
2. Document why the modeled MIP contribution is zero: compliant entries at or above the floor owe no MIP gap, while the current value panel does not contain all required quantity and capacity measures.
3. Add a statutory-deviation entry that reports affected scope and value exposure and states that the ad valorem component is modeled while the MIP contribution is not yet estimated.

**Stage B — research and validation track**

1. Retrieve Census quantity fields and units for each covered HTS10-country cell.
2. Validate kilograms for raw polysilicon and wafers.
3. Identify a defensible source for cell/module watt capacity; do not infer watts from kilograms.
4. Calculate the MIP gap rather than treating the full threshold as a universal duty:
   `max(MIP value - entered value, 0) / entered value`, adjusted only by a separately documented noncompliance share where appropriate.
5. Produce a reproducible resource containing value, quantity/capacity, unit value, data year, MIP, gap, and AVE.
6. Keep the MIP component separate and additive after the ad valorem heading rate is resolved; do not include it in a maximum-across-programs operation.
7. Activate Stage B in the headline series only after unit, coverage, outlier, and aggregate-exposure review. Otherwise retain it as a sensitivity series.

### Phase 7 — Documentation and excluded mechanics

Document, without assigning unsupported rates:

- fixed-term contract treatment;
- documentation and resale-price conditions;
- manufacturing drawback;
- foreign-trade-zone privileged status;
- onshoring tariff offsets;
- future substantially equivalent MIP arrangements; and
- the absence of a general USMCA exemption.

Update the revision changelog, policy documentation, source registry, and statutory deviations with exact official URLs and retrieval metadata.

## 3. Tests and publication gates

Required automated checks:

1. Archive sequence, hash, schema, and row-count checks for revisions 13–15.
   **Derive the expected counts from the archives this repository holds** — do not
   hardcode the figures quoted in the ChatGPT review (35,779 / 35,789 records,
   612 / 622 Chapter 99 entries), whose sourcing does not hold up (§1). Once
   re-derived locally they are fine to assert; the revision 14 row will
   necessarily be reconstructed from its change record, not from a snapshot.
2. Normalized diff assertions separating cosmetic HTML changes from substantive
   rate and scope changes. Strip tags before the next changelog run: USITC ran a
   schedule-wide typographic pass, so a raw field diff across revisions 13–15
   reports thousands of modified entries that are entirely cosmetic. Tags land in
   `description` and `units` only, so rate parsers are unaffected — but re-check
   anything matching on description text, the §232 annex parser especially.
3. **A footnote-population assertion.** Fail the ingest if the count of Chapter
   1–97 lines carrying a `9903` cross-reference footnote moves by more than a
   small tolerance between consecutive revisions without an explicit, documented
   waiver. Had this existed, §0.2 would have been caught at revision 13 instead of
   two revisions later during an unrelated size check. Assert per `(columns, type)`
   class, not on a single total — the total is stable enough to hide a swap.
4. Solar 201 boundary tests immediately before and on 2026-02-07.
5. UK pharmaceutical zero-rate and framework-partner total-duty tests.
6. A test that the 2026-07-31 Brazil and forced-labor patented-pharmaceutical
   exclusions remain active and correctly dated — see Phase 3, item 3.
7. Polysilicon tests immediately before and on 2026-12-04, which presuppose the boundary mint of Phase 4, item 7.
8. Country-tier tests for default, framework-partner, UK, Canada, and Mexico examples.
9. Product-scope tests showing raw polysilicon is MIP-only and wafers/cells/modules receive the ad valorem program.
10. Classification tests for `9903.04.60-.69`, `9903.45.21-.29`, and `9903.45.30-.36`.
11. 484(f) value-conservation and nonzero-wafer-weight tests.
12. MIP tests confirming zero above the floor, the correct gap below the floor, and additive stacking with the ad valorem component.
13. Candidate-build parity against the current published vintage, with every changed partition and aggregate rate movement explained. Inspect the Section 301 China aggregate specifically — §0.2 is the one failure mode that would move it without touching any heading or rate.

Each rate-moving phase should build to a validation root and be reviewed before repointing `latest`. The Solar 201 correction, HTS/pharmaceutical update, and polysilicon activation should remain separate vintages so their effects are attributable.

## 4. Completion criteria

The combined work is complete when:

- the §0.2 endnote collapse is explained, and either shown not to affect computed rates or corrected with Section 301 attachment migrated off the footnote path;
- revisions 13 and 15 are archived in the repository and represented as dated
  snapshots, while revision 14's JSON gap and July 31 synthetic treatment are
  documented with its Chapter 99 PDF and change record preserved;
- Solar 201 contributes zero after its confirmed termination;
- the UK pharmaceutical rate is zero and the interim-window assumption is explicit;
- the polysilicon program activates only on 2026-12-04 with correct additive and total-floor semantics;
- the wafer scope carries defensible, conserved weights;
- the MIP is either a validated quantity-based component or an explicit zero contribution with a prominent statutory deviation;
- classification and diff tooling prevent the identified silent errors; and
- candidate-build parity and boundary tests explain every intended series change.

## 5. Corrections made to the 2026-08-07 first draft

Recorded so the reasoning is auditable rather than silently overwritten.

| # | First draft said | Correction | Basis |
|---|---|---|---|
| 1 | Claude's revision 14 unobtainability claim "conflicts with the successful official static-download route recorded in the ChatGPT review"; Phase 0 should attempt the static URL | Reversed. The static host denies **all** revisions; revision 14 is permanently lost and the three archives take three different routes | Live fetch of all three URLs returned Akamai `Access Denied`; `.gitignore:16-17` and `src/pipeline/02_download_hts.R:10-12,41-47` document the block independently |
| 2 | `2026_rev_13` — 2026-07-27 | 2026-07-28 | USITC `releaseList` `releaseStartDate`; the ingest branch's own `revision_dates.csv` row. 07-27 appeared in neither source proposal |
| 3 | Archive acquisition sat inside Phase 0, behind the Solar 201 phase | Hoisted to §0, ahead of everything | Revision 15 is the current release and absent from disk; `exportList` serves only the current release, so the window closes when revision 16 publishes |
| 4 | ChatGPT credited for "exact revision-to-revision JSON accounting" | Credit withdrawn; its record counts must be re-derived locally before being asserted | Its cited sources are unreachable, so the counts have no demonstrable provenance |
| 5 | Ingesting revisions 13–15 listed as a finding both reviews agreed on | Relabeled a decision of this document | Only the ChatGPT review proposed it; the Claude review scoped itself to 14 and 15 |
| 6 | Phase 3 listed only corrections | Prepended the pharma reconciliations that already hold — 131/131 product scope, the `target_total` net-of-MFN match, and the already-correct 07-31 §301 exclusion | Prevents rework or "fixes" to working machinery |
| 7 | No test guarded the 07-31 §301 patented-pharma exclusions | Added as Phase 3 item 3 and test 5 | Correct today, unprotected, and adjacent to everything Phase 3 changes |
| 8 | Polysilicon activation date-gated but no partition minted | Added Phase 4 item 7 | Test 6 exercises a 2026-12-04 boundary that nothing in the plan created |

### Added after the 2026-08-07 acquisition run

| # | Change | Basis |
|---|---|---|
| 9 | §0 rewritten from a to-do into a completed record with hashes and validation results | Revision 15 archived while its window was open; four PDFs retrieved |
| 10 | Revision 14 reclassified from "permanently lost" to "JSON lost, Chapter 99 recovered" | `Chapter 99_2026HTSRev14.pdf`, 805 pages, from the reststop file endpoint |
| 11 | Added the `exportList` `release`-parameter trap to §0 and Phase 0 item 4 | The parameter is silently ignored; returns the current release with HTTP 200 |
| 12 | Verification log extended with seven primary-source confirmations | Both UK rate readings, the Solar 201 expiry stamp, the absence of polysilicon headings, the `.60-.66` exclusion span, and revision 15's single-item change record |
| 13 | **New §0.2 (M0), gating Phase 2** | A 98.8% deletion of `columns:['general']` endnotes at revision 13, unmentioned in any change record and invisible to every check the plan previously specified |
| 14 | Added Phase 0 item 7, test 3, and a Section 301 aggregate check to test 13 | So the §0.2 class of defect cannot recur silently |

### Still unverified

Do not rely on these without a check:

- the Solar 201 exposure and ETR figures (~$16.6B, ~0.08pp) and the polysilicon
  exposure table — both depend on the weights file, and neither was re-derived;
- **whether §0.2 changes any computed rate.** This is the single most important
  open question in the document and the only one that gates a merge. The Section
  301 China path may resolve through a products list rather than the footnote
  join, which would make the whole thing immaterial — but that trace has not been
  done, and the alternative is a silent drop of attachment on roughly 9,400
  product lines.
