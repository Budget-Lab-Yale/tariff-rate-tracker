# §301 exclusion claim-share calibration (Phase 2)

Phase 1 of the exclusion fix (todo.md §"§301 exclusion headings", landed
`d839e40`, shipped in vintage `2026-06-10-22`) zeroes the full §301 rate on
lines referencing an in-window USTR exclusion heading — `coverage_share = 1.0`,
a flagged **upper bound**, because USTR exclusions are scoped by product
*description* and typically cover a slice of an HTS10 line. Phase 2 replaces
the 1.0 with a measured claim share. This doc records what is and is not
measurable, the chosen method, and the module layout.

## Measurement reality (verified 2026-06-11)

The original plan (`docs/archive/etr_adj_handoff_2026-06-10.md` item 1) assumed
"the IMDB line-level ch99 filings carry this directly." **That is wrong.**
Both public statistical sources attribute ch99-claimed entries to the
*underlying* HTS10 commodity code:

1. **Census IMDB** (`IMP_DETL.TXT`): no 9903 commodity records exist at all.
   Checked IMDB2602 (Feb 2026): the only chapter-99 codes present are
   `9999.95.0000` (low-value estimate, 226 rows) and `9999.00.2000` (2 rows).
   The `rate_prov` field is a 2-digit category (ch99-dutiable = 69/79) that
   does not distinguish §301-excluded entries.
2. **USITC DataWeb**: commodity queries on `9903.88.69` (granularity 10),
   `990388` (granularity 8), and chapter `99` (granularity 4) for China 2025
   return only the 9999 salvage line. (Complements the 2026-05-02 finding in
   `src/download_subdivision_r_share.R` that `rateProvisionCodes` filtering is
   a 2-digit aggregate.)

For comparison, the eval's "Annex II 9903.01.32 claim-share channel"
(tariff-etr-eval `00_pull_raw_data.R` §3f) is itself **not** a filing
observation either — it splits the duty-free `rate_prov` channel by membership
in the tracker's exempt *list*. There is no public per-heading filing share
anywhere; entry-line ch99 linkage exists only in CBP confidential data.

## Method: realized-rate inversion

What IS public, per HTS10 × country × month (IMDB): customs value
(`con_val_mo`), dutiable value (`dut_val_mo`), and calculated duty
(`cal_dut_mo`). On an affected line the exclusion zeroes the §301 component
for the claimed slice, so with `realized = cal_dut / con_val`:

    realized ≈ stat_other + (1 − claim_share) × full_301
    claim_share = (stat_other + full_301 − realized) / full_301

- `stat_other` = all non-§301 statutory layers, taken from the tracker's own
  snapshots as `total_rate − rate_301` (vintage-proof: subtracting the
  snapshot's *own* `rate_301` column is correct whether the snapshot predates
  or postdates the Phase-1 hook).
- `full_301` = the line's pre-exclusion §301 rate, reconstructed per revision
  from the chapter-99 parse caches as the max non-NA rate among the line's
  §301-classified refs — the same max the engine's footnote-rate join applies,
  and time-varying (handles the Biden-ladder rate steps automatically).
- Same channel as the semiconductor end-use calibration (handoff item 2):
  divide a realized rate by a statutory one.

**Known confound:** the inversion attributes the line's entire
statutory-vs-collected gap to the exclusion. De minimis (pre-Aug-2025),
valuation, misclassification, FTZ timing, and AD/CVD (in collections, not in
`cal_dut`'s statutory layers — see `docs/adcvd_layer_design.md`) load onto the
same residual. Mitigations: raw (unclipped) shares are reported so <0 / >1
mass is visible; months are tagged `covered` / `lapsed` / `partial` by the
modeled exclusion status so lapse periods act as placebos; output is
curator-reviewed before promotion, never auto-written to the registry.

## Module layout (mirrors the USMCA share module)

| Piece | File |
|---|---|
| Affected-lines mapping | `scripts/build_s301_exclusion_lines.R` → `resources/s301_exclusion_lines.csv` (heading → referencing HTS10, unioned over cached revisions) |
| Measurement | `tools/calibrate_s301_exclusions.R` (IMDB parse + statutory join + inversion) |
| Per-line shares | `resources/s301_exclusion_claim_shares.csv` (covered months, value-weighted) |
| Per-heading summary | `resources/s301_exclusion_claim_shares_by_heading.csv` (candidate registry `coverage_share` values) |
| Monthly detail | `output/diagnostics/s301_exclusion_claims_monthly.csv` (all months incl. lapsed/partial) |
| Tests | `tests/test_s301_exclusion_calibration.R` (inversion units) |
| Consumption | curator writes the reviewed value into `resources/s301_exclusion_headings.csv::coverage_share` (per-heading), or the per-HTS10 hook extension (see below) |

Statutory input supports both snapshot layouts: a published vintage
(`actual/snapshots/valid_from=*/rates.parquet`, date-resolved incl. `bnd_*`
boundaries — preferred) and the local `data/timeseries/snapshot_<rev>.rds`
layout (day-mapped via `config/revision_dates.csv` policy dates). IMDB ZIPs
are read from `--imdb-dir` (the eval cache at
`../tariff-etr-eval/data/imdb/raw` works); missing months download from
Census only with `--download`.

Run used for the first calibration (2026-06-11):

    Rscript tools/calibrate_s301_exclusions.R \
        --imdb-dir ../tariff-etr-eval/data/imdb/raw \
        --snapshots-dir "<vintage 2026-06-10-22>/actual/snapshots" \
        --start 2025-01 --end 2026-03

## Interpretation note (statutory framing)

Unlike the USMCA share (behavioral take-up of a whole-line entitlement),
the exclusion coverage share is mostly **aggregation of heterogeneous
statutory rates to the tracker's HTS10 resolution limit** — the excluded
slice of a line legally owes 0% §301 while the rest owes the list rate.
Claiming an exclusion at entry is near-costless (cite the heading), so
take-up on the matching slice should be near 1 and the measured share
predominantly reflects legal scope, not behavior. This keeps the calibrated
tracker a statutory-rate tracker. (Same design lessons as USMCA apply:
pick a share vintage deliberately, handle zero-vs-missing joins explicitly,
and keep the calibration field (duty ratios) distinct from any eval target
that uses the same microdata.)

## First measurement (2026-06-11, window 2025-01..2026-03)

139/141 .69 lines + 3/3 .70 lines measured ($25.4B affected China trade;
2 lines on no §301 list drop out). Per-quarter value-weighted shares
(clipped), .69 / .70:

| Quarter | .69 | .70 | Era note |
|---|---|---|---|
| 2025Q1 | 0.73 | 0.56 | biased UP: de minimis still alive → 24% of raws > 1 |
| 2025Q2 | 1.00 | 0.82 | unusable: 145% stack, collections collapse (median raw 2.24) |
| 2025Q3 | 0.39 | 0.26 | post-de-minimis-repeal — stable from here |
| 2025Q4 | 0.34 | 0.27 | |
| 2026Q1 | 0.34 | 0.14 | s122/fent era, smallest stat_other |

**Stable-window estimate (2025Q3–2026Q1): ≈ 0.35 for 9903.88.69, ≈ 0.2 for
9903.88.70** — i.e. Phase 1's full-line zeroing overshoots the §301 relief on
these lines by roughly 3×. Line-level dispersion is wide (.69 IQR 0.52–1.00),
so a per-HTS10 hook extension carries real information beyond the per-heading
number.

## Status / next steps

- [x] Lines builder + first run (212 heading×line rows; .69 = 141 lines,
      .70 = 3, carve-outs .21–.28 = 8–9 each).
- [x] Calibration script + unit tests + first measurement (above).
- [x] **PROMOTED 2026-06-11 (user decision): registry `coverage_share`
      9903.88.69 = 0.35, 9903.88.70 = 0.20** (source = 'curator', stable
      window 2025Q3–2026Q1). Production effect at next rebuild: the 144
      excluded China lines carry 65% / 80% of their §301 rate instead of 0
      (Phase 1) or 100% (pre-fix).
- [x] **Per-HTS10 hook extension built (dormant)**:
      `section_301_exclusions.line_coverage_file` in the 6a-excl hook —
      lines present in the file use their measured share, affected lines
      absent keep the heading value; scope (in-window referencing lines)
      unchanged. Consumed file `resources/s301_exclusion_line_coverage.csv`
      (142 lines, stable window, min 3 measured months). Baseline key is
      commented out; scenario `config/scenarios/s301_line_coverage/` enables
      it (`TARIFF_SCENARIO=s301_line_coverage`). Promote by uncommenting in
      policy_params.yaml after a full-build parity review.
- [x] Resources claim-share CSVs hold the STABLE-WINDOW measurement
      (2025-09..2026-03, the calibration-grade artifact); the full-window
      history lives in `output/diagnostics/s301_exclusion_claims_monthly.csv`
      (regenerate any window by re-running with --start/--end).
- [ ] Optional: per-HTS10 coverage extension of the 6a-excl hook
      (`section_301_exclusions.lines_file` with hts10-level shares overriding
      heading-level; absent → behavior unchanged; parity-gated).
- [ ] The .21–.28 conditional carve-outs (`--include-carveouts`) — calibrate
      or confirm immaterial (todo.md Phase-2 item).
- [ ] RETRO caveat (unchanged from Phase 1): if USTR granted a retroactive
      extension after a lapse, the tracker models the lapse as published;
      lapse-month diagnostics in the monthly detail file are the evidence
      base for deciding whether any lapse needs a date-bounded override.
