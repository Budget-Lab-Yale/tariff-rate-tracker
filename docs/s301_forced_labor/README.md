# Section 301 forced-labor action — source of record for the Annex A exemption list

> **Historical preliminary source.** USTR's July 23, 2026 final action
> superseded this notice and `resources/s301fl_exempt_products.csv`. The live
> ACTUAL implementation uses the final resources documented in
> `docs/forced_labor_scenario.md`.

Provenance for `resources/s301fl_exempt_products.csv` (the Annex A product
exclusions formerly consumed by the `forced_labor` / `new_301` scenario; see
`docs/forced_labor_scenario.md`).

## Source

USTR "Notice of Determinations and Request for Comments Concerning Actions in
Section 301 Investigations ... Related to the Failure To Impose and Effectively
Enforce a Prohibition on the Importation of Goods Produced With Forced Labor."

- **Citation:** 91 FR 34272
- **FR document number:** 2026-11296
- **Published:** 2026-06-05
- **Action:** additional duty on all products of 60 investigated economies
  (10% / 12.5% two-tier) **except the products listed in Annex A**, proposed
  effective as the successor to the expiring §122 10% blanket (modeled turn-on
  2026-07-24).

URLs:
- FR full-text XML: https://www.federalregister.gov/documents/full_text/xml/2026/06/05/2026-11296.xml
- FR raw text:      https://www.federalregister.gov/documents/full_text/text/2026/06/05/2026-11296.txt
- govinfo PDF:      https://www.govinfo.gov/content/pkg/FR-2026-06-05/pdf/2026-11296.pdf
- USTR press release: https://ustr.gov/about/policy-offices/press-office/press-releases/2026/june/ustr-makes-findings-and-proposes-action-60-section-301-investigations-relating-failures-take-action

## Cached files

- `FR-2026-11296.xml` — FR full-text XML. Contains the notice prose, the 60
  economies, the tier logic, and the Annex A **scope description** — but **NOT**
  the Annex A product table.
- `FR-2026-11296.pdf` — govinfo PDF (74 pp). Pages 1–5 are the notice; pages
  6–73 are the Annex A product table. **The table pages are rasterized images**
  (pdftools/pdftotext extract only the ~600-char page footer from each), so the
  HTS codes are not machine-extractable.

## Why there is no `build_s301fl_annex.R`

`scripts/build_s301_brazil_annex.R` exists because the Brazil §301 annex
(FR-2026-11158) ships its exemption table as a structured `<GPOTABLE>` inside the
FR full-text XML — the builder parses each row's first `<ENT I="01">` as the
HTSUS provision and reproduces the CSV exactly (verified 2026-06-15: 1,698 hts8,
0 diff vs the committed file).

The forced-labor Annex A is **not available in any machine-readable public
rendition**: the FR XML and raw-text renditions omit the table entirely, and the
govinfo PDF renders it as images. There is therefore no parseable source to build
from. An automated builder would require OCR of the PDF table pages (or a
machine-readable annex obtained directly from USTR), neither of which is wired up.
`resources/s301fl_exempt_products.csv` (1,632 hts8) is treated as a curated input.

## Verification performed (2026-06-15)

The list cannot be diffed against an exact source (per above), but it was checked
for spurious / untraceable codes — the failure mode that affected the IEEPA
exempt list (see `memory` / `tariff_tracker_investigated_issues.md`):

- 1,629 of 1,632 codes are present in the **XML-verified** Brazil §301 annex —
  i.e. they are real HTSUS exemption provisions, not junk.
- `9802.00.91` is a standard Chapter-98 exemption.
- `9031.49.40` / `9031.49.70` are legitimate civil-aircraft instrument
  exemptions (enumerated in the Chapter-99 subchapter-III civil-aircraft notes
  and present in the Brazil annex XML).
- **No spurious codes found.**

What is NOT established: completeness / exactness against the actual Annex A
image table. To confirm that, OCR the govinfo PDF Annex A pages (6–73) or obtain
a machine-readable annex from USTR, then diff against the committed CSV.
