# Note to the Tariff Rate Tracker: computers (HS 8471) and the §232 annex parser

**From:** `statutory-vs-realized-tariffs` (John Iselin, The Budget Lab at Yale)
**Date:** 2026-11-09
**Against:** tracker publish `2026-11-01-13` (before the fix) and vintage
`2026-11-09-08` (after; rate snapshots identical to the `2026-11-08-23`
validation build of the fix); Census IMDB through 2026-08
**Related:** `docs/s232/annex_parser.md`; PR #43; `todo.md` (semiconductor
`end_use_exemption_share`, floor-country civil-aircraft step 7c);
`docs/assumptions.md` §16

## Summary

From April 6, 2026, the tracker charged computers and computer parts (HS 8471)
the 25 percent Annex I-B rate of the April 2026 §232 metals proclamation. The
proclamation does not list 8471. The annex parser picked the code up from
another line's product description, and it did the same for about 70 other
prefixes. PR #43 fixed the parser. The fix lowers the weighted statutory rate by
about 0.6 percentage points from April 6 onward.

One gap remains on heading 8471, and it has a different cause. The tracker
charges the full 25 percent §232 semiconductor rate on 8471.80.4000 (GPU and AI
accelerator cards), and importers declare almost none of it. This is the
uncalibrated `end_use_exemption_share` already listed in `todo.md`, and the
Census data are now enough to set it.

## The annex parser error (fixed)

**What we saw.** From April 2026, the gap between the tracker's statutory duty
and Census calculated duty rose by about 0.7 pp of all imports, and almost all of
the increase came from heading 8471. Over April to August 2026, 8471 imports
were $190 billion. The tracker rate on the heading was 5 to 7 percent (about 24
percent on lines with no country-specific treatment), against a declared rate of
0.1 to 0.2 percent through July. That is $11.0 billion more duty than importers
declared. The jump lines up exactly with HTS revision `2026_rev_5` (April 6),
when the tracker's import-weighted §232 rate rose from 4.52 to 5.56 percent.
Declared duty on 8471 did not move between March and April.

We first read this as an unmodeled exemption route (zero metal content, or
metal under 15 percent of weight). It was not. The problem was scope.

**The cause.** The April 2, 2026 annexes never list 8471. The code appears only
inside other lines' descriptions, for example Annex I-B 8504.90.41, "Parts of
power supplies … for automatic data processing machines or units thereof of
heading 8471." The old `extract_hts_codes` in `scripts/parse_annex_products.R`
accepted any four-digit token surrounded by whitespace as a heading
(`(?<=^|\s)\d{4}(?=\s|$)`). In `docs/s232/annexes_text.txt` (line 472) the
8504.90.41 description ends "…of heading 8471", so the parser wrote
`8471,1b,aluminum,proclamation,2026-04-06` to `resources/s232_annex_products.csv`.
Prefix matching then put every 8471 line in Annex I-B.

The same pattern added other codes that appear only in descriptions, including
8501, 8502, 8430, 843041, 843049, 851650, 850231, 8709, 8703, 8704, 8705, 8407,
8601 and 8605. For the ones we could measure outside the vehicle and engine
headings (8501, 8502, 8430, 843041/843049, 851650 and 8709), the overcharge came
to about $0.8 billion over April to August. The gaps on 8703,
8704 and 8407 cannot be split from the §232 autos and trucks programs without
the authority columns.

**The fix.** Commit `3d4cec2` (merged as PR #43, `e8ba9a8`) reads only the code
column of a `pdftotext -layout` extraction of the annexes. The regenerated
`s232_annex_products.csv` drops 73 prefixes, including every description-derived
code above, and narrows several subheadings the old parser had covered in full.
`resources/s232_annex_products.csv` now has no 8471 row.

**Effect.** The weighted statutory rate falls by about 0.6 pp from April 6
onward, and nothing before April 6 changes. On November 1, 2026, the overall
rate is 11.17 percent on comparison vintage `2026-11-09-09`, against 11.76
percent on `2026-11-01-19`. On heading 8471, the monthly gap between tracker and
declared duty falls from about $2 billion to between $46 million and $429
million:

| Month | Tracker rate on 8471, before (%) | After (%) | Declared rate (%) | Gap before ($M) | Gap after ($M) |
|---|---|---|---|---|---|
| 2026-03 | 0.34 | 0.34 | 0.14 | 66 | 66 |
| 2026-04 | 5.32 | 0.25 | 0.13 | 1,856 | 46 |
| 2026-05 | 6.45 | 0.42 | 0.10 | 2,301 | 116 |
| 2026-06 | 6.69 | 0.75 | 0.13 | 2,256 | 214 |
| 2026-07 | 5.70 | 1.14 | 0.16 | 2,426 | 429 |
| 2026-08 | 6.10 | 1.09 | 0.71 | 2,158 | 154 |

The fix also removes the EU, Korea and Switzerland versus Vietnam asymmetry on
8471.41, .49 and .70 that came from the civil-aircraft lists. The full-line
treatment of those lists in step 7c of `src/pipeline/06_calculate_rates.R` is a
separate open item in `todo.md`.

## What remains: the semiconductor rate on 8471.80.4000 (open)

The remaining 8471 gap is one line, 8471.80.4000 (units for incorporation into
ADP machines, which include discrete GPU and AI accelerator cards). The tracker
charges it the full 25 percent §232 semiconductor rate (9903.79.01, U.S. Note 39;
proclamation of January 14, 2026) from mid-January: `qualifying_share = 1` in
`resources/semi_qualifying_shares.csv`, times `1 − end_use_exemption_share`,
with the end-use share still at its uncalibrated 0
(`config/policy_params.yaml`, `section_232_headings.semiconductors`). Taiwan
supplies 80 to 96 percent of the line. This line accounts for more than all of
the remaining 8471 gap, because the rest of the heading nets slightly negative.

| Month | Imports ($M) | Tracker rate | Census rate | Census ÷ 25% | Uncollected ($M) |
|---|--:|--:|--:|--:|--:|
| 2026-01 | 297 | 13.9%* | 0.06% | 0.002 | 41 |
| 2026-02 | 339 | 25.0% | 0.58% | 0.023 | 83 |
| 2026-03 | 391 | 25.0% | 2.31% | 0.092 | 89 |
| 2026-04 | 293 | 25.0% | 0.31% | 0.012 | 73 |
| 2026-05 | 542 | 25.0% | 0.12% | 0.005 | 135 |
| 2026-06 | 969 | 25.0% | 0.02% | 0.001 | 242 |
| 2026-07 | 1,930 | 25.0% | 0.05% | 0.002 | 482 |
| 2026-08 | 1,671 | 25.0% | 13.1% | 0.52 | 200 |

\* Partial month: the rate starts mid-January.

Value-weighted over February to July, Census duty is 1.2 percent of the
statutory 25 percent. With the qualifying share at 1, that implies an end-use
exemption share of about 0.99. Nearly every card entered under the 9903.79.03–.09
carve-outs (U.S. data centers, research and development, startups and the other
end uses), which is what the tracker's own plan expected for a line dominated by
hyperscalers. The gap is $1.3 billion over February to August and grows with
import volume, which rose from about $300 million a month in early 2026 to $1.9
billion in July.

August breaks the pattern. The declared rate jumps to 13.1 percent, about half
the statutory rate, for Taiwan (13.2 percent) and Mexico (14.3 percent) alike.
We have not identified the cause. A change in the carve-outs, or in how
importers use them, would fit, and is worth checking against the HTS revisions
and CBP guidance for August.

**Suggested next step.** `todo.md` says not to change the baseline until the
end-use share is measured. It now is: set `end_use_exemption_share` for
8471.80.4000 to about 0.99 for January to July 2026 as a dated calibration, and
treat August separately until its jump is explained. A scenario overlay would do
if the baseline should stay statutory.

## Source

All figures come from the `statutory-vs-realized-tariffs` panel
(`data/processed/panel.rds`, HTS10 × country × month). The tracker rate is
`rate_h2avg` (the publish `total_rate` with that repo's HS2 and USMCA
adjustments). The declared rate is Census `cal_dut_mo / con_val_mo`. Figures are
value-weighted on monthly consumption imports. The gap on a set of cells is the
sum of `rate_h2avg * con_val_mo - cal_dut_mo` over those cells.
