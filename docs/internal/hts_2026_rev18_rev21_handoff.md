# HTS 2026 rev_18 – rev_21 ingest and USMCA refresh — hand-off

*2026-10-29, John Iselin → John Ricco. Branch `feat/ingest-2026-rev18-rev21`
(renamed from `feat/ingest-2026-rev18-rev19`). This is Part 1 of the model
update: the schedule is current through rev_21, and the USMCA monthly claim
shares run through 2026-08. No build has run on this branch yet.*

## What is on the branch

| Item | Status |
|---|---|
| rev_18 (drones §232, eff. 09-03) and rev_19 (§338 scope, eff. 09-15) | From the September work-in-progress commit `0cf8eca`. **Not reviewed or build-checked as a unit.** |
| rev_20 (eff. 09-29) | Done this session. JSON rebuilt from rev_21 (`scripts/reconstruct_hts_2026_rev_20.py`, verified against rev_20's change record: sole delta +9903.04.70). |
| rev_21 (eff. 10-09) | Done this session. Official download, stored as-served. Note text only. |
| USMCA monthly claim shares 2026-03 … 2026-08 | Pulled from DataWeb. Jan/Feb re-pulled (aggregates unchanged; they gain zero-trade rows for products that appear later in 2026, which the loader treats as no signal). |
| `tools/download_usmca_dataweb.R` | Fixed: DataWeb now rejects bare "Canada"/"Mexico" (`Incorrect country information`); names must read `Canada - CA - CAN` / `Mexico - MX - MEX`. |

## rev_20 / rev_21 content and how it is modeled

**rev_20** revises pharma §232 note 40 for the 09-29 turn-on:

- **Note 40(c) product list restated in current statistical numbering.** 131 → 149
  HTS-10 lines, same HTS-8 coverage. The old list (= our
  `resources/s232_pharma_products.csv`) named nine statistical lines that no
  longer exist, and 3004.90.9225 had been reused for a different drug group by
  the 2026 484(f) renumbering. The file now carries the rev_20 list for all
  dates. It is also the patented-pharma carve-out list for forced-labor §301
  (note 52(f)(8)) and Brazil §301 (Annex I Part B) from 07-31, so those move
  slightly from 07-31 on the changed lines. Every use is after the 07-01
  renumbering, so the current numbering is right for all of them.
- **Heading 9903.04.70** (+0%, clinical trials / R&D / non-commercial use).
  Classified as §232 (`classify_authority` range widened to .60–.70); its use
  condition is not modeled (deviation S15).
- **Definitions:** (c)(i) excludes excipients and inactive ingredients; (c)(iii)
  adds unpatented animal-health products to "generic"; (i) sends articles that
  are neither patented nor generic to 9903.04.69. All sub-HTS-10; they belong
  in the uncalibrated `exempt_share` / `generic_share` (S15, F1).
- rev_20 is policy-dated 09-29, so it owns the turn-on and `bnd_2026-09-29`
  drops as edge-coincident (the rev_16/rev_18 pattern).
- **Not in rev_20 or rev_21:** the Canadian import bans (PP 11061–11063).
  Deviation S13 stands.

**rev_21** restates one §301 exclusion (9903.88.69, metal-shredder parts) from
8479.90.9596 to 8479.90.9591 after the 07-01 484(f) split. Exclusion scope is
side-data since rev_13, so the line is in the new
`resources/s301_exclusion_lines_curated.csv`, which
`scripts/build_s301_exclusion_lines.R` now appends (rebuilt locally: the same
heading × line pairs as the hand edit). Three other 9903.88.69 lines were split
on 07-01, but note 20 still names only the old codes, so their successors pay
the full §301 rate from 07-01 (deviation S16, recheck each revision).

## ⚠ The USMCA refresh moves the baseline at every date

The baseline uses `usmca_shares: mode: since` (2025-07 through the newest
monthly file), and the loader picks up new files automatically. With the
2026-03…08 files present, the pooled claim share — the "settled" USMCA rate
in `actual` — drops:

| | Jul 2025–Feb 2026 | Jul 2025–Aug 2026 |
|---|---|---|
| Canada | 0.870 | 0.840 |
| Mexico | 0.885 | 0.874 |

About 13% of Canada + Mexico trade sits in cells whose pooled share moves more
than 10 pp. Lower claiming means a higher statutory rate on CA/MX USMCA-eligible
lines **in every partition, including 2025**. This is the designed behavior, but
it is a series revision, and it changes the input to the statutory-vs-realized
paper's settled-rate convention. **Decide whether to keep it** or to pin the
window end (the loader has no end-month key today; it would be a small
addition). The monthly shares by themselves: Canada 0.80–0.84 and Mexico
0.83–0.90 across Jan–Aug 2026, with July/August the lowest for Mexico (0.834).

## Verified

- `tests/test_hts_2026_rev20_rev21_ingest.R` (new): 11/11.
- CI parity (`weight_mode: unweighted`): preflight; daily series 72 pass /
  1 skip; weights resolution 16/16; annex parser 25/25 (with poppler loaded);
  `test_rate_calculation.R` 138/138.
- `test_drones_232.R` 26/26, `test_s338.R` 69/69, `test_s338_hts_rates.R` 16/16.

## For you

1. **Reconcile with `feat/s338-2026-09-15-scope`** (the branch the 09-09 vintage
   was published from — not on GitHub). It already models the 09-15 §338 scope
   change, which this branch's rev_19 work also does. Push it and decide which
   carries §338 into `master`.
2. **Review rev_18 / rev_19** (`0cf8eca`); nobody has reviewed them yet.
3. **The baseline USMCA window** — keep the automatic extension or pin it.
4. **Validation build:** `sbatch scripts/submit_build_array.sh --config
   config/build/rev18_rev21_ingest.yaml` (publishes under `.validation/`, does
   not move `latest`); compare against `2026-08-31-12` with
   `scripts/compare_vintages.R`. The config header lists the expected moves.
5. Then Part 2 of the update: the full run with `usmca_monthly` set to
   `publish: true`, which needs these monthly files.
