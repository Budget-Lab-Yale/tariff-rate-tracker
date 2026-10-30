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

## USMCA claim shares: two windows split at the SCOTUS ruling

**Decided 2026-10-30.** The baseline was `usmca_shares: mode: since`: one pool
from 2025-07 through the newest monthly file, applied to every date. With the
2026-03…08 files it would have lowered the pooled claim share at every date,
including 2025 (Canada 0.870 → 0.840, Mexico 0.885 → 0.874). Instead the
baseline now uses the new `mode: periods`: two fixed windows, split at the
Supreme Court's IEEPA ruling (*Learning Resources v. Trump*, 2026-02-20).

| Window | Applies to | Canada | Mexico |
|---|---|---|---|
| 2025-07 … 2026-02 (pre-ruling) | every date before 2026-02-20 | 0.870 | 0.885 |
| 2026-03 … 2026-08 (post-ruling) | 2026-02-20 on | 0.805 | 0.862 |

(Pooled claim share = USMCA-claimed customs value ÷ total customs value, all
products.) The pre-ruling window is the old baseline window, so dates before
2026-02-20 should not move. Every month in a window must have a file; the
second window is extended by hand in `config/policy_params.yaml` as new
months land. Coverage after the split: 98% of Canada/Mexico 2025 import value
still has its own HTS10 share, 1.6–1.7% uses the HS8 fallback, 0.13% falls to
zero.

## Verified

- `tests/test_hts_2026_rev20_rev21_ingest.R` (new): 11/11.
- CI parity (`weight_mode: unweighted`): preflight; daily series 72 pass /
  1 skip; weights resolution 16/16; annex parser 25/25 (with poppler loaded);
  `test_rate_calculation.R` 139/139 (with the new `periods` loader test).
- `test_drones_232.R` 26/26, `test_s338.R` 69/69, `test_s338_hts_rates.R` 16/16.

## For you

1. **Reconcile with `feat/s338-2026-09-15-scope`** (the branch the 09-09 vintage
   was published from — not on GitHub). It already models the 09-15 §338 scope
   change, which this branch's rev_19 work also does. **Decided 2026-10-30:
   this branch's rev_19 §338 rates go into `master`** (in September they
   matched the 09-09 vintage's `bnd_2026-09-15` exactly, 20,422 Canada rows).
   Check that branch for anything else it carries before retiring it.
2. **Review rev_18 / rev_19** (`0cf8eca`); nobody has reviewed them yet.
3. **The baseline USMCA window** — decided: two windows split at the SCOTUS
   ruling (above).
4. **Validation build:** `sbatch scripts/submit_build_array.sh --config
   config/build/rev18_rev21_ingest.yaml` (publishes under `.validation/`, does
   not move `latest`); compare against `2026-08-31-12` with
   `scripts/compare_vintages.R`. The config header lists the expected moves.
5. Then Part 2 of the update: the full run with `usmca_monthly` set to
   `publish: true`, which needs these monthly files.
