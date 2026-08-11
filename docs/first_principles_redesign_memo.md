# Design memo: the model, rebuilt from the law's actual paper trail

*2026-08-10 · John Ricco (with Claude) · status: proposal for discussion*

## Why this memo exists

The current model was not designed; it accreted. Its original author pointed an
early LLM at the USITC's JSON files and said "make code that calculates tariff
rates," and everything since — the AuthoritySpec refactor, the interactions
memo, two years of hand-transcribed CSVs — has been renovation of a structure
whose foundation was never surveyed. This memo does the survey. It answers two
questions from first principles, ignoring the existing code entirely:

1. **What information does tariff law contain** that a model computing
   country × product rates for each day must represent?
2. **Where does the government actually publish that information, and in what
   form?** This question — the one the original code never asked — turns out
   to have a much better answer than we believed.

Everything below marked *(verified)* was confirmed by direct download or
inspection on 2026-08-10, most of it by research agents whose full reports are
preserved in the session record.

## Part 1 — What tariff law consists of

The target quantity is: the statutory duty rate for product *p* from country
*c* entered for consumption on day *d*. Everything the law contributes to that
number falls into a small ontology.

**The schedule baseline.** The normal (MFN) rate for every tariff line, plus
the column-2 rates for embargoed countries and the preference programs that
override by country. Rates come in kinds — percentage, cents-per-kilo,
compound, quota-dependent. Critically, the classification itself is a time
series: codes appear, die, and renumber (the product axis drifted from 20,204
distinct 10-digit codes in the 2025 basic edition to 20,422 by late 2026,
*verified* against our own snapshots), so "product" means "code under the
classification in force on day d."

**Programs.** Every action — a §232 proclamation, an IEEPA order, a §301
notice — is one object with six slots:

1. *Identity and authority* — which statute, which documents created it;
2. *Country scope* — a roster, possibly with per-country rates and conditions
   (USMCA eligibility, framework-deal status);
3. *Product scope* — a code list, or all-products-minus-a-list, or a
   content-based rule ("the metal share of the article's value");
4. *Rate semantics* — add, floor, top-up-to-a-total-including-MFN, cap,
   value-split, specific duty, minimum import price;
5. *Time* — effective date in entry-for-consumption terms (usually with a
   12:01 a.m. timestamp), in-transit savings clauses, sunsets, scheduled
   future steps;
6. *Interactions* — the exception sentences by which one program yields to
   another, in the three flavors the interactions memo catalogued (own
   exemption list; skip-if-covered-by named programs; arithmetic couplings
   and caps).

**The date discipline.** Every fact has three dates — announced, effective,
codified into the HTS — and the model runs on *effective*. Every parameter is
a piecewise-constant function of the entry date.

**Honest slots for the unobservable.** Value splits need content shares;
minimum import prices need prices; quotas need quantities. The structure
carries these as declared, visible parameters (estimated or zero), never as
silent code branches.

That is the whole of it. An instance of this structure is an instance of law.
This part mostly ratifies where AuthoritySpec plus the interactions memo were
already heading; what is new is treating the baseline schedule and the
classification drift as first-class members of the same time-indexed system.

## Part 2 — Where the government publishes it

Tariff law reaches the public through three channels playing three roles:

| Channel | Role | Author |
|---|---|---|
| Federal Register (proclamations, EOs, USTR notices) | the **diffs** — where a tariff is legally created, with its rates, rosters, semantics sentences, and effective dates | White House / USTR |
| Harmonized Tariff Schedule, revised ~monthly | the **state** — the consolidated current law: rate lines in chapters 1–97, program stubs in chapter 99, and the U.S. notes carrying rosters, exemption lists, and interaction sentences | USITC |
| CSMS bulletins | the **operations** — filing instructions restating each change with code lists and exact timestamps | CBP |

What we established about each, and how it revises what this repo believed:

**The HTS rate lines are fully machine-readable, past and present.**
*(verified)* Beyond the live export the pipeline already uses, USITC publishes
every archived revision back to 2017 as JSON/CSV/XLSX at

    https://www.usitc.gov/sites/default/files/tata/hts/hts_<year>_revision_<n>_json.json

— 148 releases, including all of 2025 and 2026 (the "missing" 2026 rev_14 is
there). Exact validity windows for all 178 releases come as JSON from
`https://hts.usitc.gov/reststop/releaseList`, which means
`config/revision_dates.csv`'s HTS-dating half duplicates an official feed
(the *policy*-effective-date half remains our own analysis). The download
script's belief that history is unreachable, and this memo's earlier drafts'
drama about our snapshots being the only copy, were both wrong: the archive
sits behind an unlinked-but-public URL pattern.

**The chapter 99 notes are machine-readable — for the current revision
only.** *(verified)* An unadvertised endpoint,

    https://hts.usitc.gov/reststop/getChapterNotes?doc=99

returns the complete current notes as a ~5 MB structured HTML document:
country rosters as tagged list items ("(1) Algeria, subject to an additional
duty of 30%"), full exemption code lists as text, all 192 occurrences of
"shall not apply." This is, as text, exactly the material we have
hand-transcribed into `resources/*.csv` for two years. Two hard limits, both
proven: the endpoint ignores any request for a past release (byte-identical
responses under real and bogus release parameters), and the complete endpoint
inventory read out of the site's own JavaScript
(`currentRelease, exportList, file, getChapterNotes, getSectionNotes,
getNotices, getRates, getRates99, ranges, releaseDetails, releaseList,
search`) contains nothing that serves notes by release. Historical note text
officially exists only as one PDF per revision, downloadable via the `file`
endpoint. A new "HTS Online" site is announced for 2027, so this surface will
change.

**Presidential-document annexes in the Federal Register are page images.**
*(verified)* The FR API serves clean full-text XML of the operative prose —
including the formulaic effective-date language ("entered for consumption, or
withdrawn from warehouse for consumption, on or after 12:01 a.m. …") — but
the product-list annexes are scanned images: 152 for the September 2025
reciprocal annex, 53 for the June 2026 metals proclamation, 327 for the
forced-labor final action. The bulk-XML repository embeds the same images;
"9903" appears zero times in the text of the entire Liberation Day issue.
Nothing in the CFR/eCFR carries chapter 99 text.

**But the images are readable now.** *(verified live)* A vision-capable model
reads the rasterized pages directly. As a demonstration, page 7 of the
forced-labor Annex A — pages this repo's own README calls "not
machine-extractable" — was rendered and read, and all ten codes on the page
matched `resources/s301fl_exempt_products.csv` exactly. "Not extractable"
described the text-extraction tools of 2024, not the readers of 2026.

**CSMS bulletins are the text backstop.** *(verified)* Each is a permanent,
dated HTML page (enumerable — the govdelivery URL id is the CSMS number in
hexadecimal) carrying the chapter-99 headings, code lists, timestamps, and
the stacking order as customs actually applied it. Often the only *text*
copy of a list the FR printed as images.

**The reconstructable history of the notes.** *(verified)* Five dated
machine-readable snapshots of the full notes exist: Wayback captures of
2024-01-02, 2025-04-22, 2025-09-08, 2026-02-20, and a 3.3 MB capture
committed 2025-11-02 to a stranger's GitHub repo (`janLajko/tarriff-simulator`).
The American Presidency Project (presidency.ucsb.edu) additionally transcribes
presidential annexes as searchable HTML — EO 14257's country-rate table and
HTS-8 exception list are full text there. Everything else is per-revision
PDFs, all downloadable, all readable as above. Definitive negatives, so the
search is closed: no official archive of structured notes, no archive.today
captures, no Common Crawl captures, no public mirror of CBP's broker-side
structured tariff records, and the academic trackers (WITS, Teti's public
files, PIIE) carry averages or MFN detail, not chapter-99 program rules.

**Why the ecosystem is shaped this way.** The HTS data model dates to 1988:
one good, one line, one rate — a perfect fit for policy that *was* the lines.
Chapter 99 was the junk drawer for "temporary" measures, and when temporary
measures became most of tariff policy by value, their machinery went into
prose notes because prose is the one format that fits a data model with no
fields for rosters or interactions. The public machine-readable export
faithfully copies the 1988 worldview. (CBP distributes structured chapter-99
tariff records to customs brokers over its private filing network; the
operational state got a schema, the public record did not.)

**The punchline of Part 2:** the law is machine-readable at exactly one point
in time — now. Nobody, government or archivist, has been saving what the
window shows. This repo's own pipeline has been contemporaneously harvesting
the rate lines since early 2025 without anyone framing it as archiving; the
notes deserve the same and never got it.

## The design

Three layers, replacing the current five-or-so muddled ones.

### Layer 1: the harvester

A small collector that runs whenever a new HTS revision or FR document lands:
fetch the rate-line export, fetch `getChapterNotes` (99 and any other chapter
we use), fetch new FR documents (API subscription) and CSMS bulletins, record
`releaseList`, and file everything permanently in the document store the
interactions memo already proposed (id, type, FR/release number, what it
governs, validity window, checksum). From switch-on day the messy-PDF problem
stops growing. Build it before the 2027 site migration.

### Layer 2: the reader

Turning stored documents into instances of the Part-1 structure is an
extraction task with bookkeeping, not a parsing task:

- **Deterministic tier** where real structure exists: release windows (JSON),
  heading rate text (a dozen formulaic templates — "The duty provided in the
  applicable subheading + 12.5%"), FR text tables where present.
- **Model tier** for prose and images: note subdivisions → six-slot program
  objects; interaction sentences → declared interaction blocks; effective-date
  formulae → dates; rasterized annexes → code lists. Every extracted fact
  carries its citation (document, note, subdivision) as a required field.
- **Verification tier, the load-bearing one: redundancy, never trust.** The
  same fact almost always exists in two or three channels (note text, CSMS
  bulletin, annex, APP transcription). Code lists are sets; two sets either
  match exactly or they don't. Independent readings (model + classical OCR)
  must agree; every read code must exist in that revision's schedule;
  disagreement anywhere flags a human. Double-entry bookkeeping for law.
- **Reconciliation as a standing check:** every FR diff must materialize in
  the next HTS state; every state change (the official change records give a
  third opinion) must trace to a diff. Anything unexplained on either side is
  a flag. This is the check that catches the next polysilicon automatically —
  today that comparison happens only in an analyst's head.

### Layer 3: the engine

The state of the law at any moment is small parameter objects, not a big
table: per program, a rate table over revisions × countries (kilobytes), a
scope mask over products (~20k booleans), exemption masks, interaction terms.
The panel is one broadcast expression over a dense array of revision ×
product × country × program — the union product axis over all revisions costs
~1% padding plus an is-this-code-alive mask (drift measured above). Floors
and caps are elementwise min/max in a declared order. The daily series is an
index from day to revision plus one weighted contraction; ETRs are grouped
sums through the crosswalk; a counterfactual is a swapped parameter object,
and a scenario axis comes essentially free. Inputs are megabytes; the full
output tensor is ~1.2 GB. Written in Python on JAX, it runs on CPU (seconds
to a minute — no GPU dependency, no big-memory Slurm queue) and on GPU
unchanged when scenario volume warrants. An engine that only does broadcast
arithmetic over cited masks physically cannot hide a policy judgment — the
completion, and the enforcement mechanism, of the interactions memo's design
standard.

## What this dissolves

The 234 GB build peak and the 3¼-hour wall clock (artifacts of materializing
a 292M-row long table in copy-heavy R); the 10k-line accreted parser layer as
a concept; interactions trapped in code; provenance as scattered YAML
comments (3 of ~60 resource CSVs carry any in-file provenance today, and the
repo stores none of the dozen-plus proclamations it models — one saved
"notice" is literally a 404 page); and the un-audited status of the
hand-built lists.

## What this does not dissolve

The transcription-and-verification labor is the model and remains so — the
design changes who does the first pass (models, with citations) and how it is
checked (exact set-agreement across channels), not whether care is needed.
The two years of hand-built CSVs become the *audit counterparty* for the
backfill: re-extract history from the stored documents, diff against the
human transcription, and every agreement is a verified fact while every
disagreement is a found bug (in whichever direction — the Brazil annex
re-extraction already matched 1,698 codes exactly, and the forced-labor
Annex A had never been verified against its images at all until page 7 was
spot-checked for this memo). Existing output contracts survive: the engine
writes the same per-revision parquet panels tariff-model reads today, and
parity against the frozen R goldens gates every migration step.

## Migration sketch (each step parity- or evidence-gated)

1. **Start the harvester now** (cheap, independent, urgent-before-2027; also
   backfill the official JSON archive including rev_14, the five notes
   snapshots, and the per-revision chapter 99 PDFs into the document store).
2. **Stand up the engine** against the *existing* compiled spec objects,
   exported from R as data; gate on exact parity with the frozen golden panel.
   This is the Python/JAX cutover, isolated from any source-reading changes.
3. **Stand up the reader** program by program, newest first; gate each
   program on mask-level agreement with the hand-built CSVs, adjudicate
   disagreements, retire the R adapter for that program.
4. **Backfill history** from the archived documents with the same machinery;
   the R pipeline retires when the last program's masks come from the reader.

Steps 1–2 are independent and can start immediately; the interactions memo's
narrow December solar patch proceeds in R regardless.

## Validation: two live tests (2026-08-10, same day as the survey)

**The reader test — passed with a perfect score.** A fresh agent was given the
current `getChapterNotes?doc=99` capture and told to extract the forced-labor
§301 program (U.S. note 52) into the six-slot structure *before* being allowed
to look at any repo file, then diff against the hand-built counterparties.
Results:

- The 60-economy roster, in all four tiers (17 countries at a flat 10%, 38 at
  a flat 12.5%, EU-27 + Taiwan at a 10% total-duty floor, Japan/South
  Korea/Switzerland at a 12.5% floor), matched `config/policy_params.yaml`
  country-for-country with zero mismatches.
- The exemption lists — subdivisions 52(b) common (863 codes), (c) particular
  articles (16), (d) civil aircraft (541), (e) pharmaceutical use (700), 2,120
  codes in all — matched `resources/s301fl_final_common_exemptions.csv` as
  sets, exactly, subdivision by subdivision. The only discrepancy that
  appeared en route was the reader's own normalization bug (truncating seven
  10-digit codes to 8), which the set-diff itself surfaced and resolved —
  the verification tier catching its own reader, as designed.
- The interactions claim held: 52(f) enumerates exactly the eight §232
  programs the interactions memo lists; polysilicon appears nowhere in note
  52 as of revision 15, and raw polysilicon sits in the 52(b) list — both as
  that memo predicted. The December solar bug's legal facts are confirmed
  from the primary text.

One structural lesson: the note text alone cannot yield the rates — note 52
carries rosters and lists while the percentages live on headings
9903.05.20–.84 in the schedule lines. The reader needed both sources, which
is the Part-2 division of labor (lines = the table, notes = the rules about
the table) showing up as a hard requirement rather than a description.

**The recovery test — rev_14 is back, by a route that proves the point.**
The "unavailable" 2026 rev_14 JSON went through three states in ten days,
each observed directly: around Aug 3 it was genuinely absent (the live
export had flipped to rev_15 and the archive row was not yet posted — the
archive lags its revision by a few days, which is what
`revision_dates.csv`'s "Revision 14 JSON is unavailable" note recorded); by
Aug 10 the archive list page carried a full rev_14 row with JSON/CSV/XLSX
links (verified in a same-day Wayback capture of the list page); and yet on
the evening of Aug 10 every direct fetch from this environment returned 403,
the day's research traffic having tripped the archive host's bot
protection. The file was finally recovered via the Wayback Machine, which
turned out to hold a capture of the JSON itself made on Aug 1 — *while
rev_14 was still current*. Validated (35,789 records, 622 chapter-99 lines,
the note-52 headings present with their rates) and placed at
`data/hts_archives/hts_2026_rev_14.json.gz`. Lessons, all of them harvester
arguments: availability is a function of *when you ask*; the archive lags
the law; hosts block; and the copy that saved us existed only because
someone archived during the four-day window — exactly the behavior the
harvester makes systematic.

## Open questions

- Chapter 99 is not the only notes chapter we lean on (note-16-style §232
  material, chapter-98 provisions): enumerate which `getChapterNotes?doc=N`
  pulls belong in the harvester.
- The reader's model tier: which extractions demand a second independent
  model reading versus classical OCR as the second key.
- Where the document store lives (in-repo vs model-data root with committed
  checksums) — inherited from the interactions memo, unresolved.
- Weights: the Census import-weights build is untouched by this memo and
  ports on its own schedule.
- Whether step 2 exports spec objects from R once (a frozen bridge) or
  repeatedly during the transition window.
