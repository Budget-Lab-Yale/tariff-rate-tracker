# Statutory-measurement checks surfaced by the eta ETR-effect figure (July 2026)

*Incoming from the July 2026 tariff-update blog (`tariff-update-blog-june2026`,
Figure 2b/2c + `docs/FIG2B_OUTLIERS.md`). The eta calibration measures
`realized = statutory × (1 − η)`, so any statutory over-assignment in the
tracker shows up as a spuriously large η. Expressing the ηs as ETR effects
(statutory vs realized rate by partner × GTAP) flagged four places where the
STATUTORY side looks like tracker measurement rather than avoidance. Numbers
below are from the eta diagnostic grid at tracker vintage `2026-06-13-11`
(`tariff-etr-adj` supplemental `eta_by_partner_gtap.csv`).*

## 1. Electricity (HS 2716) — energy-rate classification

Canadian electricity ($1.8B) carries a **statutory ETR averaging ~31%** over
the calibration window (2025m5–2026m2) — i.e. the full non-energy
fentanyl-IEEPA rate path (25% → 35%), not the 10% **energy** rate. Check
whether HS 2716 is included in the energy product list for the Canada/Mexico
IEEPA carve-out (and whether it should be tariffed at all — duties on
transmission entries are effectively never collected, realized ≈ 0.4%).
Impact: cosmetic for the overall ETR (0.08% of trade) but it produces the
single largest bar in eta ETR-effect figures.

## 2. §232 derivative content basis (metal products; part of iron & steel)

GTAP `fmp` (metal products, $48B) shows statutory 31–63% by partner and a
6.2pp statutory-vs-realized gap — the largest *actionable* contributor to the
economy-wide eta wedge (0.12pp of 1.03pp; `i_s` adds 0.08pp). CBP assesses
§232 duties on derivative articles on the **declared metal content only**;
if the tracker applies the 50% rate to full customs value on derivative HTS
lines (9903.81.9x-style), statutory is systematically overstated and the eta
absorbs it. Verify how derivative content shares are encoded per line.

## 3. USMCA claim shares in the eta-calibration statutory baseline

The calibration's statutory baseline uses 2024-H2 claim shares, which were
near zero for energy (MFN was already zero — no incentive to certify).
Actual claiming is now ~100%, so Canadian gas shows statutory 9.3% vs
realized 0.1% (η ≈ 0.99), similarly Canadian crude and canola. The tracker
already carries updated claim-share scenarios (`usmca_2024`, `usmca_dec2025`).
**Decision needed** (with the eta owners): re-base the calibration statutory
on current claim shares (moves the take-up surge out of η into statutory) or
keep it in η by design — the surge is a real compliance response, but a
figure axis labeled "statutory" arguably should not embed stale claim shares.

## 4. Late-2025 reciprocal agricultural exemptions (ch10/11/15)

ROW etas for processed rice, paddy rice, and vegetable oils cluster tightly
at ~0.54–0.56 — a common-carve-out signature, not sector-specific avoidance.
Check the reciprocal-tariff agricultural exemption product lists and their
effective dates (Nov 2025 carve-outs) against what the statutory measure
applies over the calibration window. Sectors: `pcr` ($1.0B, statutory 31.9% →
realized 14.0%), `vol` ($10.5B, 12.4% → 5.4%); `pdr`/`wht`/`gro` are sub-$1B.

## Cross-references

- Diagnosis + figure-reformat plan: `tariff-update-blog-june2026/docs/FIG2B_OUTLIERS.md`
- Eta apply contract + calibration: `tariff-etr-adj/results/README.md`
- Related earlier handoff: `docs/etr_adj_handoff_2026-06-10.md`
