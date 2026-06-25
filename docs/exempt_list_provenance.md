# Exempt-list provenance audit (2026-06-15)

Verification that the per-authority **product-exemption** lists in `resources/`
are traceable to their own legal source, prompted by the June-2026 IEEPA
exempt-list prune. Conclusion up front: **the IEEPA pollution did not spread to
§122 or §301** — each of those lists is sound against its own authority.

## Background: the IEEPA pollution

`resources/ieepa_exempt_products.csv` had accumulated **1,822 untraceable HTS10
codes** (~$380B 2024 imports) with no basis in the printed IEEPA Annex II
enumeration (US Note 2(v)(iii)(a)). They entered via the Tariff-ETRs
`ieepa_reciprocal.yaml` merge (commit `df1bf3b`) and the HTS10 expansion
(`01e8e76`, `tools/expand_ieepa_exempt.R`), which imported every ETRs `rate=0`
line — bundling ETRs-zeroed residue, §232 program members (handled by stacking,
not a list entry), and universal Ch88 aircraft. Pruned in `552693d`
(audit `d6c8d9a`); see `scripts/prune_ieepa_exempt_untraceable.R` and the
investigated-issues log. **This merge touched only `ieepa_exempt_products.csv`.**

## Method

Each non-IEEPA exempt list was checked against its **own** authoritative
enumeration — not against IEEPA's Annex II. Using IEEPA's Annex II as the
yardstick produces false positives (see the §122 lesson below).

| List | Authority | Reproducible? |
|------|-----------|---------------|
| `ieepa_exempt_products.csv` | IEEPA reciprocal, US Note 2(v)(iii)(a) — `resources/annex_ii_first_appearance.csv` | yes (`build_annex_ii_dates.R`) |
| `s122_exempt_products.csv` | §122, **US Note 2(aa)** to subch. III ch.99 (`data/us_notes/chapter99_*.txt`) | by inspection |
| `s301_brazil_exempt_products.csv` | §301 Brazil, **FR-2026-11158** Annex (GPOTABLE in FR XML) | yes (`build_s301_brazil_annex.R`) |
| `s301fl_exempt_products.csv` | §301 forced-labor, **FR-2026-11296** Annex A (91 FR 34272) | no — table is image-only (see `s301_forced_labor/README.md`) |

## Findings

### §122 — clean
The §122 exemptions live in **US Note 2(aa)**, self-contained, *not* a reuse of
IEEPA's note 2(v). The product-list exemptions are:
- heading **9903.03.04** / (aa)(iii): 11 "particular articles" (religious / specialty);
- heading **9903.03.05** / (aa)(iv): **546 civil-aircraft hts8 codes** (GN6 scope).

Subdivisions (aa)(v)–(viii) are authority-overlap (232 / auto / wood / MHD /
semiconductor), Canada/Mexico USMCA, and CAFTA-DR textiles — these are *not*
product-CSV exemptions; the tracker handles them via stacking and USMCA shares.

Against this authority, **1,654 of 1,656** `s122_exempt_products.csv` codes trace
to Annex II + note 2(aa). The 2 residuals were both benign: a malformed 10-digit
row (`8505110070`, **fixed** → `85051100`) and `9031.49.70` (a civil-aircraft
instrument, legitimately enumerated in the Ch99 subch-III notes).

### The reference-mismatch lesson (why IEEPA's yardstick was wrong)
A first pass matched the §122/§301 lists against IEEPA's Annex II and flagged
~540 "untraceable" codes (plastics 3917/3926, rubber 40xx, instruments 90xx).
**537 of those 540 are the §122 civil-aircraft list (heading 9903.03.05).** Same
HTS codes, opposite correctness, because the carve-out differs in **country
scope**:
- **§122** note 2(aa)(iv): civil aircraft exempt for *"the product of any
  country"* — **universal** → the codes belong in `s122_exempt_products.csv`.
- **IEEPA** reciprocal: the aircraft carve-out is **country-conditional** (deal
  countries only, via `floor_exempt_products.csv` keyed by country-group) → a
  universal full-line entry there wrongly exempted non-deal countries, which is
  exactly why the IEEPA prune dropped them.

### §301 Brazil — clean (exact source match)
Re-extracting the Annex from the cached `docs/s301_brazil/FR-2026-11158.xml`
(builder logic) yields 1,698 hts8, **identical** to the committed CSV — 0 codes
added or missing.

### §301 forced-labor — no spurious codes; source not reproducible
The Annex A product table (~1,632 hts8) is **not available in any machine-readable
public rendition** — the FR XML and raw-text omit it, and the govinfo PDF renders
it as images (table pages 6–73 extract only page footers). So, unlike Brazil,
there is no parseable source and no automated builder. The list was checked for
junk instead: **1,629 of 1,632 codes are in the XML-verified Brazil annex**,
`9802.00.91` is a standard Ch98 exemption, and `9031.49.40/.70` are legitimate
civil-aircraft instruments. **No spurious codes.** Exactness/completeness vs the
image table is unverified (would require OCR or a USTR machine-readable annex).
Full provenance: `docs/s301_forced_labor/README.md`.

## Changes applied (this audit)
- **Fixed** `resources/s122_exempt_products.csv`: `8505110070` → `85051100`
  (10-digit stat code transcribed from the note's odd `8505.11.0070` formatting;
  never matched, since the calculator keys exemptions on hts8). List unchanged at
  1,656 rows.
- **Cached** the forced-labor source of record under `docs/s301_forced_labor/`
  (FR-2026-11296 XML + PDF) with a provenance README.

## Open items
- `s301fl_exempt_products.csv` exactness vs Annex A — needs OCR of the
  FR-2026-11296 PDF (pp. 6–73) or a machine-readable USTR annex.
