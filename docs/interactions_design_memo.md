# Design memo: interactions are the last policy still trapped in code

*2026-08-10 · John Ricco (with Claude) · status: proposal for discussion*

## Why this memo exists

While verifying the polysilicon Section 232 implementation we found a live bug,
arriving December 4, 2026: the model silently drops the forced-labor Section
301 duty (10–12.5%) on solar cells and modules the day the polysilicon tariff
turns on. Roughly $16.5 billion a year of imports, roughly $1.5–2 billion a
year of understated duty. The bug is not a typo. It is the predictable product
of a design gap, and this memo is about the gap, not the bug.

## How the law communicates tariff interactions

A tariff bill is a stack of independent layers — one per legal authority (MFN
base rate, a broad-based tariff like the forced-labor §301, product tariffs
like the §232 family, country tariffs like §301 China or Brazil). **The default
rule is that layers simply add.** Interactions between layers are exceptions,
and the law communicates every one of them the same way: as a specific written
sentence in a specific document. They come in exactly three flavors:

1. **"My tariff doesn't apply to these products"** — an exemption list.
   (Forced-labor Note 52(b) lists raw polysilicon, among ~860 codes.)
2. **"My tariff doesn't apply to products covered by that other tariff"** — a
   cross-reference to named programs. (Note 52(f): skip articles under the
   steel, aluminum, copper, autos, trucks, wood, patented-pharma, and
   semiconductor §232 programs. Eight programs, by name.)
3. **"My tariff adjusts arithmetically based on the other"** — value splits
   and caps. (Reciprocal taxed only the non-metal share of a §232 metal
   article; the EU framework caps some totals at 15%.)

There is no general principle like "§232 beats §301." Only sentences.

## Where those sentences live, and what we store

| Document | Author | Format | Uniquely carries |
|---|---|---|---|
| Proclamation / EO | President (via FR) | prose PDF + annexes | new tariff: rates, dates, "in addition to" clauses, product annexes |
| USTR notice | USTR (via FR) | prose PDF + annexes | §301 actions: same elements |
| HTS revision, JSON export | USITC | **machine-readable** | heading codes, rate text, some date gates |
| HTS revision, full PDF | USITC | prose | the U.S. notes: exemption lists and interaction sentences |

The critical fact about the whole system: **the interaction sentences exist
only in prose** — proclamation clauses and the Chapter 99 U.S. notes — never
in the JSON export our pipeline parses. Every exemption list and every
interaction rule therefore reaches the code through a one-time human
transcription. The repo currently commits all 47 JSON files but discards most
of the prose documents it transcribed from (Chapter 99 note-text PDFs are not
kept; Federal Register PDFs are scattered). We keep the format machines can
read and throw away the format the law is actually written in.

## How the current model works (one-paragraph version)

For each HTS revision date the pipeline builds a **snapshot**: one row per
product × country (~5M rows), one **column per authority** (`base_rate`,
`rate_232`, `rate_s301fl`, …), plus a total. The calculator fills columns one
program at a time — rate from config or parsed from the JSON, scope from
hand-typed CSVs, dates from config — then interaction logic adjusts columns
before the sum. The daily series maps calendar days to snapshots and
aggregates with import weights.

## What is config and what is code — the boundary that matters

Thanks to the AuthoritySpec refactor, **what a tariff charges** is data: rates,
rosters, product lists, dates all live in `config/policy_params.yaml` and
`resources/*.csv`, get compiled into spec objects, and the calculator reads
them generically. Change Vietnam's rate in the YAML; no code changes.

**How tariffs interact is still code.** Three flavors, three ad-hoc
implementations:

- Flavor 1 (exemption lists): in the spec. Fine.
- Flavor 2 (program cross-references): hand-coded masks in the calculator, one
  per authority (forced-labor, Brazil §301, §338), all sharing one helper that
  answers "is this row covered by **any** §232 program?" — a paraphrase. The
  law says *eight named programs*; the code says *all of them, forever,
  including future ones*.
- Flavor 3 (value splits/caps): the metal-share machinery, welded to one
  hardcoded pairing (§232 metals vs. the reciprocal/§122/fentanyl family).

The solar bug is exactly the flavor-2 paraphrase meeting the first §232
program (polysilicon) that the law did **not** put on the list. Note 52(a)
makes stacking the default; nothing exempts solar cells/modules; the
proclamation says its duty adds to everything. Law: 12.5 + 15 = 27.5%.
Model: 15%. Verified empirically on a December-4 test snapshot.

A second instance of the same disease, harmless only by luck: the metal-share
trigger ("any §232 rate > 0 → scale the content-split family by the non-metal
share, defaulting to zero") also wrongly deletes the reciprocal tariff on
solar — money-neutral only because the reciprocal layer is dead.

## The design standard

Good model code represents every relevant dimension of policy in a
generalized data structure; an instance of the structure is a policy setting;
the engine is policy-free arithmetic over instances. The current code meets
this for rates/scope/dates and fails it for interactions, provenance, and the
document layer.

## Proposal

### 1. One program object, six slots — interactions become the sixth

```yaml
section_301_forced_labor:
  authority:  section_301
  source:     "U.S. note 52; USTR FR Doc 2026-XXXXX"     # citation, required
  products:   all_except: {list: s301fl_common_exemptions.csv, cite: "52(b)"}
  countries:  {VN: 0.125, DE: {floor: 0.10}, ...}         # cite: headings .20-.84
  semantics:  additive | floor_to_total | specific | price_floor
  time:       {on: 2026-07-24}
  interactions:
    - skip_products_covered_by:
        programs: [s232_steel, s232_aluminum, s232_copper, s232_autos,
                   s232_trucks, s232_wood, s232_pharma_patented, s232_semis]
        cite: "U.S. note 52(f), as of 2026 rev_13"
```

Design positions, each deliberate:

- **Interactions are declared on the program that yields, written the way the
  law writes them** (per-program exception sentences, in the three flavors). A
  small compiler flattens all declarations into the pairwise factor table the
  engine runs. Structure mirrors law; engine gets math. Carve-outs and value
  splits become the same declared thing — a factor (0, or a share, or a cap)
  applied to a cited scope — because mathematically they always were.
- **Citation is a required field, not a comment.** Every list, rate, and
  interaction names the document and subdivision it transcribes. Drift becomes
  visible: an auditor can walk the structure holding the note text. When
  USITC eventually amends Note 52(f) to add polysilicon, the change lands as
  an edit to a cited block, not a silent divergence.
- **Order of operations is explicit.** Adds commute; floors and caps don't.
  The engine evaluates in a declared order instead of an accidental one.

### 2. Snapshot rows keep the program label

Today all §232 programs write into one `rate_232` column, so "which program
covered this row" — the question every flavor-2 sentence asks — is
unanswerable from the data, which is why the paraphrase existed at all.
Compute per-program contributions in a long intermediate (row per product ×
country × program), evaluate interactions there, then collapse to today's wide
schema so downstream consumers (tariff-model) see no change.

### 3. Store the documents

Commit (or annex with committed checksums, if size demands) every document we
transcribe from: per revision, the JSON *and* the Chapter 99 PDF *and* the
change record; plus every proclamation/EO/USTR notice with its annexes. One
manifest: document id, type, FR number, what it governs, which revisions it's
valid for. Two standing checks follow: every program slot must cite a stored
document, and every document's validity window must reach the newest revision
(catches upstream amendments to text we transcribed months ago).

## Migration order (each step parity-gated)

1. **Thread program identity** through the calculator into the long
   intermediate. Mechanical; zero rate changes; parity must be exact.
2. **Interactions as data**: add the `interactions:` blocks, build the
   compiler, delete the three hand-coded masks and the hardwired metal-share
   trigger. The one rate-affecting step — gated on reproducing today's numbers
   everywhere **except** the known polysilicon divergence, which flips to the
   correct 27.5%.
3. **Citations and the document store**, paid incrementally; new work must
   cite from day one, backfill as touched.

## Open questions for discussion

- Brazil §301's §232 carve-out (note 50(a)(vi)) and §338's (note 51(c)): read
  their actual text before writing their `interactions:` blocks — enumerated
  programs or generic language? (Forced-labor's is enumerated; verified.)
- Memory: the long intermediate on a 384GB build — compute per-partition and
  never materialize globally, or accept the peak?
- Does the price-floor (MIP) semantics slot stay documented-zero, or grow a
  quantity-based estimate on the sensitivity track?
- Where does the document store live — in-repo (size) vs. model-data root
  (annexed, checksums committed)?

## Relationship to existing work

This is the completion of the AuthoritySpec refactor, not a new direction: the
repo's own counterfactual-generality writeup already records that the stacking
class is hardcoded and displacement is metal-§232-only. The immediate solar
bug can also be patched narrowly (make the forced-labor mask enumerate its
eight programs) if December approaches faster than this lands; the patch is an
afternoon and is subsumed by step 2.
