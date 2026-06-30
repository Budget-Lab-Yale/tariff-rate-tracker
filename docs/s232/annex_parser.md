# §232 Annex Product Parser

`resources/s232_annex_products.csv` is the canonical mapping from HS prefixes
to §232 annex tier (1a / 1b / 2 / 3) consumed by the rate engine in
`src/pipeline/06_calculate_rates.R::calculate_rates_for_revision()`. As of 2026-05-19
that CSV is **regenerable** from the HTSUS U.S. Notes PDF, not purely
hand-curated.

```bash
# Default: parse latest local chapter99 PDF, regenerate CSV
Rscript tools/scrape_us_notes.R --annex

# Pin to a specific revision
Rscript tools/scrape_us_notes.R --annex --annex-revision 2026_rev_6

# Preview without writing
Rscript tools/scrape_us_notes.R --annex --dry-run
```

This document covers: what the parser does, why the subdivision → annex
mapping is what it is, how the curator/parser merge works, and what is
deliberately out of scope.

## Background

The April 2 2026 proclamation (effective 2026-04-06, HTS revision `2026_rev_5`)
replaced the single-rate §232 regime with four product annexes:

| Annex | Rate                    | Stylized intent                      |
|-------|-------------------------|--------------------------------------|
| I-A   | +50%                    | "Core metals + close derivatives"    |
| I-B   | +25%                    | "Downstream manufactured articles"   |
| II    | (removed from scope)    | Products dropped from §232 entirely  |
| III   | 15% floor (ad val total)| "Further downstream, temporary"      |

HTSUS Chapter 99 codifies this as headings `9903.82.01` through `9903.82.19`,
which apply to products enumerated in U.S. Note 16(c)(i) through (c)(x).

## What the parser does

`tools/scrape_us_notes.R::parse_annex_products()` reads the per-revision
chapter99 PDF (`data/us_notes/chapter99_<revision>.pdf`), locates Note 16 by
its "16. (a)" anchor, walks the subdivisions (c)(i) through (c)(x), and
extracts the HS prefixes listed in each. Each subdivision is mapped to one
`(annex, metal_type)` pair via the constant `ANNEX_SUBDIVISION_MAP`:

| Subdivision | Annex | Metal type |
|-------------|-------|------------|
| (c)(i)      | 1a    | aluminum   |
| (c)(ii)     | 1a    | aluminum   |
| (c)(iii)    | 1a    | steel      |
| (c)(iv)     | 1a    | steel      |
| (c)(v)      | 1a    | copper     |
| (c)(vi)     | 1b    | aluminum   |
| (c)(vii)    | 1b    | steel      |
| (c)(viii)   | 1b    | copper     |
| (c)(ix)     | 3     | aluminum   |
| (c)(x)      | 3     | steel      |

### Why this mapping (and not the obvious one)

A naive reading of Note 16(c) would suggest "primary chapters in (c)(i),
(c)(iii), (c)(v) get Annex I-A; everything called 'derivative' gets I-B; the
floor lists get III." That's wrong.

The proclamation lumps **primaries together with their close derivatives** in
the 50% bucket (Annex I-A) and reserves the 25% bucket (Annex I-B) for the
broader downstream lists. That's why subdivisions (c)(ii) "Derivative
aluminum articles" and (c)(iv) "Derivative steel articles" map to Annex I-A
even though their titles say "Derivative".

The mapping above was **derived empirically** by reverse-engineering the
hand-curated baseline against the PDF subdivisions: for each subdivision, we
checked which annex label the curator assigned to those prefixes, and the
modal mapping is what's encoded in `ANNEX_SUBDIVISION_MAP`. The mapping is
asserted in `tests/run_tests_annex_parser.R`.

## What the parser does NOT extract

- **Annex II (removed from scope).** Note 16(c) doesn't list removed
  products — they're simply absent from §232 entirely. The 169 annex_2
  entries in `resources/s232_annex_products.csv` come from the curator path
  (source = `proclamation`) and are preserved across parser runs.

- **The conditioned rate overlays** described in Note 16(d) through (i):
  UK 95%-content qualifying (9903.82.04/.05), Russia (9903.82.14–.17),
  motorcycle parts (9903.82.13), USMCA limited-quantity vehicle parts added
  in rev_6 (9903.82.18/.19). The parser identifies which products are in
  scope under each annex; the rate-engine layer in
  `src/pipeline/06_calculate_rates.R` applies the country/condition overlays
  separately.

- **The 9903.82.01 zero-metal-content carve-out.** Modeled separately as
  `section_232_annexes.exemptions.zero_metal_content` in `policy_params.yaml`
  (aggregate_share scaffolding, dormant until calibrated).

## Curator ↔ parser merge rules

The CSV's `source` column has two values:

- `proclamation` — curator-curated entries from the original Federal Register
  annex PDFs. Includes all annex_2 (removed) entries and any narrowing
  overrides for prefixes the parser would otherwise label differently.

- `us_note_16` — produced by the parser from Note 16(c) of the supplied
  chapter99 PDF.

`build_annex_products_for_revision()` merges them with these rules:

1. **Curator entries win on prefix overlap.** Any parsed row whose
   `hts_prefix` exactly matches a curator prefix is dropped.
2. **Parser entries are regenerated wholesale** on each run — previous
   us_note_16 rows are discarded and replaced with the current parse output.
   This means future revisions that *remove* a code from Note 16(c) drop
   that row cleanly rather than leaving stale data.
3. The output CSV is rewritten with curator entries first, parser entries
   second.

The merge is **idempotent**: re-running `--annex` on the same revision PDF
produces a byte-identical CSV. There's a test for this in
`tests/run_tests_annex_parser.R::"rev_5 merge is idempotent"`.

### When to add a curator override

Three legitimate reasons:

1. **An annex_2 (removed) product** — Note 16(c) won't list it, so the
   parser can't find it. Hand-add with `source = 'proclamation'`.
2. **A more-specific override needed.** If Note 16(c) puts a product in
   one annex but the rate-engine semantics demand a different assignment
   for a specific HS10 range, add a curator override at the longer prefix
   length so the rate engine's longest-prefix-wins logic picks it.
3. **A pre-published change.** If a Federal Register proclamation modifies
   the lists but the HTSUS hasn't been republished yet, you can stage the
   addition as a curator entry and it will survive subsequent regenerations.

## Effective-date semantics

All parser entries are stamped with `annex_regime_effective_date()`, which
reads from `policy_params.yaml::section_232_annexes.effective_date`
(currently `2026-04-06`). This is **not** the effective_date of the parsed
revision — it's the date the annex regime became operative.

Concrete example: rev_5 (effective 2026-04-06) and rev_7 (effective
2026-04-29) are byte-identical. The products in rev_7's Note 16(c) actually
entered §232 scope on 2026-04-06 via rev_5; rev_7 just republished the same
content with corrections to Note 16(a)/(e) text. Stamping rev_7's parser
output with 2026-04-29 would be wrong.

**Known limitation.** If a future proclamation expands Note 16(c) by adding
new products at a *later* effective date, this scheme will mis-date those
additions. Fixing that would require per-prefix dating (tracking which
revision first introduced each prefix), which the current parser does not
produce. Open for now; revisit when such an expansion happens.

## Chapter-range filter

`extract_codes()` discards numeric tokens outside HS chapters 72–95 as
defense against false positives (calendar years on page headers, page
numbers, proclamation IDs). The §232 annex covers metals (72–76) through
manufactured derivatives in machinery, electricals, vehicles, and parts
(82–95). Annex II "removed" products in lower chapters (04, 21, 22, 27–39,
66, 96) come from the curator path, not the parser, so the filter doesn't
drop anything we'd otherwise capture.

If a future proclamation expands annex scope to a different chapter range,
the filter needs to widen.

## Cross-list duplicates

A few products legitimately appear in both `(c)(vi)` (aluminum) and
`(c)(vii)` (steel) — e.g. `8412909070`, `8412909075`, `8483405020`,
`8501640110`. Note 16(c) says: "If an article is classified in a provision
that is present on multiple lists, use the aggregate weight of the listed
metals."

The CSV preserves both rows (different `metal_type`). Downstream,
`load_annex_products()` in `src/model/data_loaders.R` drops the `metal_type` column
and de-duplicates by `hts_prefix`. This is benign because:

- Both rows share the same `annex` value (all 4 dupes are annex_1b).
- The rate engine's metal_type-aware logic (Russia aluminum surcharge etc.)
  reads metal_type from `resources/s232_derivative_products.csv`, not from
  the annex CSV.

If a future product appears in cross-lists under *different* annex labels,
the dedup tiebreak becomes load-bearing and we'd need to revisit this.

## Validation

`tests/run_tests_annex_parser.R` covers:

- Subdivision map invariants (10 entries, expected annex partition).
- `latest_local_chapter99_revision()` ordering by effective_date.
- `annex_regime_effective_date()` reads from policy_params.yaml correctly.
- `parse_annex_products()` error paths (missing effective_date, missing PDF).
- Integration: parsing the rev_5 PDF yields ~738 prefix rows in chapters
  72-95, with all 4 annex tiers represented, and no false-positive year
  strings like `2025`, `2026`, `2027`.
- `build_annex_products_for_revision()` is idempotent and preserves all
  curator entries.

The integration block skips if the rev_5 PDF isn't cached locally, so CI
without the PDF still runs the unit tests.

## Extending to new revisions

When a new HTSUS revision lands:

1. Add the revision row to `config/revision_dates.csv` with its
   `effective_date`.
2. Download the chapter99 PDF (`tools/scrape_us_notes.R --download-pdfs` if
   batch, or the per-revision helper).
3. Re-run `Rscript tools/scrape_us_notes.R --annex`. The CSV updates
   automatically; the regeneration message reports any new parser entries
   or curator suppressions.
4. Inspect the diff in `resources/s232_annex_products.csv` before committing.

If the new revision adds *new conditioned rate overlays* (new 9903.82.NN
codes — like rev_6 did with .18/.19) those need separate rate-engine work in
`06_calculate_rates.R`; the parser only captures the product lists, not the
rate logic. See `todo.md` for the modeling backlog.
