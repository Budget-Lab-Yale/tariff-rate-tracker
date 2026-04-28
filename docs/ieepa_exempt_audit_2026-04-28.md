# IEEPA Annex II exempt-list audit

**Date**: 2026-04-28
**Triggered by**: `tariff-etr-eval/docs/tracker_miss_report.md` Round 3 follow-up
**Scope**: audit `src/expand_ieepa_exempt.R` and `resources/ieepa_exempt_products.csv` against the literal text of US Note 2(v)(iii) (the Annex II / Annex A enumeration referenced by 9903.01.32).

## Source authority

`data/us_notes/chapter99_2026_rev_6.txt:12382-12800` reproduces the verbatim US Note text:

> (a) As provided for in heading 9903.01.32, the additional duties imposed by headings 9903.01.25, 9903.01.35, 9903.01.39, 9903.01.63, 9903.02.01–9903.02.73, 9903.02.79–9903.02.80, 9903.02.82–9903.02.83, and 9903.02.87–9903.02.88 shall not apply to products classified in the following subheadings of the HTSUS: …

This confirms the legal-scope finding: Annex II applies uniformly to the universal baseline, China-specific (9903.01.63), all of Phase 2 country-specific (9903.02.01–.73), and the Swiss/Liechtenstein floor structure entries (9903.02.82–.83, .87–.88). There is no separate Phase 2 list. The list of exempt subheadings then runs ~400 lines, partly at HS4/HS6 (whole headings) and partly at HS8 (specific subheadings).

## Audit results — `expand_ieepa_exempt.R`

| Fix | Source | Authority | Verdict |
|---|---|---|---|
| 1. HTS8→HTS10 expansion (+1,993) | Existing HTS8 entries | None added; expansion of a base list assumed authoritative | **Inherits whatever's in the base list.** Compounds any error in the source. |
| 2. Ch98 statutory (+101) | US Note 2(v)(i) | Ch98 except 9802.00.40/50/60/80 | **Correct** per legal text. |
| 3. ITA prefix expansion (+59) | `c("8471", "847330", "8486", "8523", "8524", "8541", "8542")` | US Note 2(v)(iii) "ITA prefixes" | **Two over-extensions confirmed (8523, 8541).** See below. |
| 4. Ch97 Berman (+101) | Berman Amendment (19 USC 2505), Ch97 | "TPC confirms exempt" per code comment | Plausible. Not audited in detail. |
| 5. Ch49 Berman (+101) | Berman Amendment, Ch49 | 19 USC 2505(c) "informational materials" | Plausible but borderline cases (4910 calendars, 4907 stamps, 4911 advertising). Not audited in detail. |

## Fix 3 — ITA prefix over-extensions

Verified against the literal subheading list at `data/us_notes/chapter99_2026_rev_6.txt:12791-12800`.

### Legal text (rev_6, Apr 2026)

The 8471–8542 segment of the exempt list reads (reformatted):

```
8471                                       (whole heading exempt)
8473.30                                    (whole subheading exempt)
8486                                       (whole heading exempt)
8505.11.0070                               (specific)
8517.13.00, 8517.62.00                     (specific)
8523.51.00                                 (specific — only 8523.51!)
8524                                       (whole heading exempt)
8528.52.00                                 (specific)
8541.10.00, 8541.21.00, 8541.29.00,
8541.30.00, 8541.41.00,
8541.49.10, 8541.49.70, 8541.49.80, 8541.49.95,
8541.51.00, 8541.59.00, 8541.90.00         (specific — NOT 8541.42, NOT 8541.43)
8542                                       (whole heading exempt)
```

### Tracker prefix list vs. legal scope

| Tracker prefix in Fix 3 | Legal text | Status |
|---|---|---|
| `8471` | `8471` (whole heading) | **Correct** |
| `847330` | `8473.30` (whole subheading) | **Correct** |
| `8486` | `8486` (whole heading) | **Correct** |
| `8523` | only `8523.51.00` | **TOO BROAD** |
| `8524` | `8524` (whole heading) | **Correct** |
| `8541` | specific subheadings only — *not* 8541.42, *not* 8541.43 | **TOO BROAD** |
| `8542` | `8542` (whole heading) | **Correct** |

### Concretely wrong entries in `ieepa_exempt_products.csv`

For 8541, the file currently contains four HTS10 codes that are not on the legal exempt list:

| HTS10 | Subheading | Description |
|---|---|---|
| 8541420010 | 8541.42 | PV cells, not assembled in modules |
| 8541420080 | 8541.42 | PV cells, not assembled in modules |
| 8541430010 | 8541.43 | **PV cells assembled in modules** — Round 2 trackermiss case (Indonesia, $66.1M Sep 2025) |
| 8541430080 | 8541.43 | PV cells assembled in modules |

For 8523, the file contains ~22 HTS10 codes outside the only-exempt 8523.51 subheading. Listed here at the HS6 level:

| HS6 | Description | Tracker exempt? | Legal? |
|---|---|---|---|
| 8523.21 | Magnetic stripe cards | yes | no |
| 8523.29 | Other magnetic media | yes (~12 codes) | no |
| 8523.41 | Optical media (recordable) | yes | no |
| 8523.49 | Optical media (DVDs/CDs) | yes (~5 codes) | no |
| **8523.51** | **Solid-state non-volatile storage** | **yes** | **yes** |
| 8523.52 | Smart cards | yes | no |
| 8523.59 | Other semiconductor media | yes | no |
| 8523.80 | Other media | yes (~2 codes) | no |

### Why this matters for trackermiss

The Round 2 / Round 3 Pattern 1 case for **Indonesia 8541.43.00.10 (PV cells, $66.1M Sep 2025, 18.96% implied rate)** was directly attributed to the universal exempt list zeroing Phase 2 reciprocal. The exempt-list audit shows 8541.43 was wrongly placed on the list via Fix 3's broad `8541` prefix. Removing 8541.42/8541.43 from the exempt list closes this specific trackermiss case at the source — the tracker will then apply Phase 2 reciprocal to PV cells correctly, with no architectural change to the case_when.

The Vietnam 8518.30 and France 8411.91 cases are *not* explained by Fix 3 (those HS6 ranges are outside the ITA prefixes). They were added via Fix 1 (HTS8→HTS10 expansion of a base entry). Removing them requires inspecting the base HTS8 list — which is out of scope for this audit but is the natural next step.

## Fix 1 — base HTS8 list audit (deferred)

The 1,993 codes added by Fix 1 inherit whatever is in the original `ieepa_exempt_products.csv` at HTS8 level. The 8518.30, 8411.91, 1511.90 entries from the Round 2 spot-checks all came from this layer. A full audit requires comparing the base list against the literal subheading enumeration at `chapter99_2026_rev_6.txt:12395-12800` (~400 lines of HS subheadings). This is mechanical but not done in this pass.

Recommended approach:

1. Parse the literal subheading list from the rev_6 text into a clean canonical CSV (`resources/annex_ii_canonical_2026_rev_6.csv`) at the HS-subheading level.
2. Compare the current base HTS8 list against the canonical set; flag mismatches.
3. Diff against later revisions (rev_17, rev_32, 2026_rev_4) to ensure the EO 14346 amendments are reflected.

## Recommended changes to `expand_ieepa_exempt.R`

Replace the `ita_prefixes` vector with a structured list of (legal-prefix, scope) pairs:

```r
# US Note 2(v)(iii) ITA exempt subheadings — legal text at chapter99 rev_6,
# us_notes pp. 99-III-5..11. Only entries stated as bare headings/subheadings
# in the legal text are expanded here; specific HS8s are listed individually.
ita_exempt_legal <- list(
  list(prefix = "8471",   note = "whole heading"),       # computers
  list(prefix = "847330", note = "whole subheading"),    # parts of 8471
  list(prefix = "8486",   note = "whole heading"),       # semi mfg equipment
  list(prefix = "852351", note = "subheading only"),     # solid-state storage (not all of 8523)
  list(prefix = "8524",   note = "whole heading"),       # electronic displays
  list(prefix = "8542",   note = "whole heading")        # ICs
)
# 8541 is enumerated, NOT a broad prefix in the legal text. The tracker's
# base HTS8 list should already contain the specific 8541 subheadings; if
# Fix 1 expansion fails to cover them, add them here individually:
ita_exempt_specific_hs8 <- c(
  "85411000", "85412100", "85412900", "85413000", "85414100",
  "85414910", "85414970", "85414980", "85414995",
  "85415100", "85415900", "85419000"
)
# Specific HS8 entries also in the legal text (not from broad prefixes):
specific_hs8_extras <- c(
  "85051100",  # the legal text has 8505.11.0070 specifically — keep at HTS10
  "85171300", "85176200",
  "85285200"
)
```

Then change the prefix-match loop to iterate over `ita_exempt_legal$prefix`, and add the specific HS8s explicitly.

## Recommended cleanup of `resources/ieepa_exempt_products.csv`

Remove the four PV cell entries:

```
8541420010
8541420080
8541430010
8541430080
```

Remove the 8523 entries outside 8523.51 (preserve 8523.51.xx). The full removal list, drawn from the current file:

```
8523210000
8523291000  8523292000  8523293000  8523294010  8523294020
8523295010  8523295020  8523296000  8523297010  8523297020
8523298000  8523299000
8523410000
8523492010  8523492020  8523493000  8523494000  8523495000
8523520010  8523520090
8523590000
8523801000  8523802000
```

## Caveats

- The audit was performed against rev_6 (April 2026 revision text). Later revisions (rev_17, rev_32, 2026_rev_4) may have amended the exempt subheading list. The Sept 5, 2025 EO 14346 amendments added chs 25, 26, 28, 29, 47, 71, 72, 75 — none of which affect the 8523/8541 findings. A full diff against `chapter99_2026_rev_4.pdf` is recommended before applying changes.
- The audit does **not** address the Fix 1 base-list inheritance question. Round 2 cases 8518.30, 1511.90, 8411.91, 0901.11 are in the base HTS8 list, not added by Fix 3 — verifying those is a separate, larger task.
- Removing the 26 confirmed-wrong entries will close some Pattern 1 trackermiss but not all of it. The remainder of Pattern 1 still requires either (a) the deferred Fix 1 audit, or (b) accepting that the residual is importer 9903.01.32 non-claim.

## Next steps (proposed, not applied here)

1. Apply the four 8541 + 22 8523 removals to `ieepa_exempt_products.csv`.
2. Update `expand_ieepa_exempt.R` Fix 3 to use the structured list above, so a future regeneration doesn't reintroduce the over-extensions.
3. Re-run the build and validate against TPC + Tariff-ETRs benchmarks. Expect: TPC overall ETR moves up slightly (tracker now collects PV-cell tariff); Tariff-ETRs gap may widen for PV-heavy partners (Indonesia, Vietnam, Malaysia) until Tariff-ETRs makes the same correction.
4. Re-share trackermiss diagnostic with `tariff-etr-eval` to quantify the Pattern 1 reduction.
5. Schedule the deferred Fix 1 base-list audit as a follow-up.
