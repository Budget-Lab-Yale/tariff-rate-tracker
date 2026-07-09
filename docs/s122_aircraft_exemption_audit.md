# §122 civil-aircraft exemption audit — full-line application of a use-conditional carve-out

**Audited 2026-07-08.** Trigger: the §232 annex route calibration
(`tools/calibrate_s232_annex_routes.R`) found India/Japan/Vietnam annex cells
clustering at realized = exactly 10.0% on lines the tracker holds §122-exempt
— importers paying the §122 blanket on exempt-modeled lines.

**Finding: the tracker under-states §122-era statutory duty by ≈ $800M/month.**
The 546 civil-aircraft codes on `resources/s122_exempt_products.csv` carry a
**use-conditional** exemption (note 2(aa)(iv): GN6 civil-aircraft criteria)
that the engine applies **full-line**; ~61% of the import value on those lines
is not aircraft-certified and is actually paying the 10%.

## 1. The legal structure (note 2(aa), rev_5 text, `data/us_notes/chapter99_2026_rev_5.txt`)

The tracker's 1,656-row `s122_exempt_products.csv` partitions exactly against
the printed note (this audit, parse of the rev_5 text):

| Printed source | Codes | Condition | Tracker treatment | Verdict |
|---|---|---|---|---|
| (aa)(ii) / heading 9903.03.03 | **1,098** | none — "articles the product of any country … classifiable in the following subheadings" | full-line exempt | **correct** |
| (aa)(iii) / 9903.03.04 | 11 | particular articles | full-line exempt | correct |
| **(aa)(iv) / 9903.03.05** | **546** | civil aircraft, engines, parts, simulators "**that otherwise meet the criteria of general note 6**" — a **USE test**, product of any country | **full-line exempt** | **over-exemption** |
| untraceable | 1 (9031.49.70) | — | known benign (provenance audit 2026-06-15) | — |

The (aa)(iv) enumeration lists eligible HTS8 *provisions*, but only
GN6-certified civil-aircraft entries within them are exempt. A consumer
loudspeaker under 8518.30.20 or an industrial engine part under 8412.90.90
owes the full 10% — the tracker exempts the whole line. Same defect class as
the IEEPA aircraft lesson in `docs/exempt_list_provenance.md` (there the
carve-out was country-conditional and applied universally; here it is
use-conditional and applied full-line). The provenance audit verified the
codes *trace to the printed lists* — it did not check whether the lists'
*conditions* were modeled; this audit closes that gap.

## 2. Empirical utilization (IMDB 2026-03/04/05, $39.5B)

Method: (aa)(iv)-listed cells with no §232/§301 contamination
(`rate_232 = rate_301 = rate_301_cs = 0`), ex-USMCA (CA/MX excluded to avoid
share scaling), against the `latest` (2026-07-01-16) statutory snapshots.
Each cell-month classified by whether realized (`cal_dut/con_val`) sits
nearer the tracker's exempt total or exempt + 10%.

| | value share |
|---|---|
| exempt claimed (GN6 aircraft) | **39.2%** |
| **paying the §122 10%** | **60.8%** |

Stable across months (Mar 60.5% / Apr 63.1% / May 58.8%). By chapter — the
split validates the mechanism:

| HS2 | $B (3mo) | paying share | reading |
|---|---|---|---|
| 88 aircraft | 5.1 | **2.9%** | genuinely aircraft — exemption real and claimed |
| 84 machinery | 16.0 | 54.2% | mixed |
| 85 electronics | 9.8 | **89.0%** | overwhelmingly non-aircraft |
| 90 instruments | 3.4 | 86.6% | |
| 39 plastics | 1.4 | 92.2% | |

Line level (`output/diagnostics/s122_aircraft_line_utilization.csv`, 956
lines): jet engines/parts 8411.91.90.85 ($3.6B) and airplanes 8802.40 pay
≈ 0; loudspeakers 8518.30.20 pay 99.4%, power supplies 8504.40.95/.60 pay
87–100%, plastics 3926.90.99.89 pay 99.5%.

**Magnitude: ≈ $8.0B/month of value paying a 10% the tracker models at 0 —
≈ $800M/month of statutory duty understated** on this clean subset alone
(the 232/301-stacked and USMCA slices add more, partially offset by
stacking displacement). Direction: tracker statutory is too LOW — the
negative-η class on these chapters from 2026-02-24 on.

## 3. Reinterpretation of the route-calibration signature

The India/Japan/Vietnam "us_origin" exact-10.0% mass in the §232 route
calibration is **this**, not note-16(e) claims: non-aircraft entries on
(aa)(iv) lines paying §122 where the tracker's without-232 branch (`T_exit`)
was mis-modeled as ≈ 0. After the fix, `T_exit` on those cells becomes ≈ 10%
and that mass reclassifies to **exit (strong)** — articles exiting §232 and
paying the §122 blanket. The us_origin promotion candidates (MX ≈ 0.09,
CA ≈ 0.06) were measured ex-USMCA-scaling and are unaffected by this audit's
clean subset, but should be re-derived after the fix lands (their T_exit
carries USMCA-scaled §122).

## 4. Fix — IMPLEMENTED 2026-07-08 (statutory-faithful, USMCA-style utilization)

Landed (uncommitted at time of writing; validation Slurm 17428463):
`scripts/build_s122_exempt_conditions.R` stamps the `condition` column
(1,115 `none` + 541 `gn6_civil_aircraft`) from the rev_5 note text and builds
`resources/s122_aircraft_utilization.csv` (955 measured lines) from §2's
measurement. `.resolve_s122_exempt()` (adapter) now returns
`{hts8, gn6_hts8}`; `.resolve_s122_gn6_utilization()` loads the per-line
shares; `build_authority_specs()` bakes all three onto
`section_122$exempt_products`. `apply_section122()` (06 step 6b) keeps the
unconditional set full-line exempt and scales the GN6 set by
`(1 − exempt_share)` with **measured → HS2-mean → full-exemption** fallback.
Legacy CSV (no `condition` column) falls back to full-line exemption
(byte-identical to the old behavior). Tests: `test_s122_aircraft_scaling.R`
(9, drives the step directly), `test_exempt_sets_in_spec.R` updated (23),
rate-calc 107/0, daily 81/0, adapter 55/55. The plan as originally proposed:

1. **Split the condition in the resource**: add a `condition` column to
   `s122_exempt_products.csv` (`none` for (aa)(ii)/(iii) + 9031.49.70;
   `gn6_civil_aircraft` for the 546 (aa)(iv) codes), derivable from the
   note text.
2. **Engine**: apply the (aa)(iv) exemption scaled by a per-line
   **GN6-utilization share** — `rate_s122 = 10% × (1 − exempt_share)` on
   conditional lines — consumed from a measured file
   (`resources/s122_aircraft_utilization.csv`, from §2's measurement).
   Claiming 9903.03.05 at entry is near-costless, so the measured exempt
   share ≈ the legal GN6 scope share (the U3 statutory framing) — this keeps
   the tracker a statutory tracker. Unmeasured lines: default to the
   HS2-level share (not 1.0 — the current full-line treatment is the known
   bias).
3. **Validation**: hook-on/off single-revision diff (rev_4 era+ only;
   pre-2026-02-24 unaffected); expected channel = rate_s122 0 → ~6% mean on
   the conditional non-aircraft mass, ETR up in ch84/85/90 from Feb 24.
4. **Registry**: new U-item (utilization family, alongside U1/U3); P/S-class
   note that (aa)(iv) was modeled unconditional 2026-02-24 → fix date.
   (Registry file in active edit 2026-07-08 — entry to be added by curator.)
5. **Downstream**: this moves §122-era statutory UP materially → the pending
   eval re-pull + adj recalibration must use the post-fix vintage; the eta
   on ch84/85/90 §122-era cells will shift toward zero (part of today's
   "compliance gap" is this modeling artifact, with the sign opposite to
   issue #13's).

## 5. Cross-checks and caveats

- ch88 ≈ 0% paying + engines ≈ 0% is the positive control: where trade IS
  aircraft, the exemption is claimed. The measured "paying" mass is not an
  artifact of AD/CVD or MPF noise (realized on paying lines ≈ base + 10%,
  e.g. 3926.90.99 ≈ 15.3% vs base 5.3%).
- 9802.00.50.60 (ch98 repair value) shows 19.8% paying — the value-basis
  (B-class) conversion interacts; exclude ch98 from the utilization file or
  handle via the existing ch98 machinery.
- The old "ITA list" shorthand for this file (todo/memory, e.g. the §122×semi
  stacking note) is wrong: the list is note 2(aa)'s own (ii)+(iii)+(iv)
  enumerations. The semi 8471/8473 prefixes were checked: **all 24 sit on
  (aa)(ii)** (unconditional) — the "§122 × semi stacking: no fix needed"
  conclusion is unaffected by this audit.
