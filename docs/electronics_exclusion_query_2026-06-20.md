# Query for daily-rate-tracker: is the electronics reciprocal-tariff exclusion applied?

**From:** tariff-etr-adj (eta/alpha calibration for the Budget Lab Tariff Model)
**Date:** 2026-06-20
**Status:** question / hypothesis to rule out — not a confirmed tracker bug
**Contact path:** this note lives at `tariff-etr-adj/docs/` and is delivered to
the daily-rate-tracker workspace.

## TL;DR — the ask

We calibrate trade-weight adjustments (α) by comparing GTAP's predicted,
tariff-driven re-sourcing against what actually happened in the import data. The
**electronics** sector (GTAP `ele` = computers/electronic/optical) is the single
biggest place where GTAP's prediction and reality disagree — and the disagreement
has a shape that looks like a **rate-specification** issue, not a behavioral one.

**Before we attribute it to GTAP's elasticities, we want to rule out the tracker
rates that feed the model.** Specifically:

> **Does the tracker apply the April-2025 reciprocal-tariff electronics exclusion
> (smartphones / laptops / semiconductors / displays — the carve-out commonly
> cited under HTS heading 9903.01.32), and if so, for which HS10 codes, which
> partner countries, and over which date range?**

If electronics are *not* excluded from the reciprocal schedule in the rate build,
the per-country electronics rates we feed GTAP are likely mis-specified *relative
to each other*, which would explain the pattern below.

## What we see in the data

For each source region we compare the 2024 within-`ele` source share, GTAP's
predicted post-tariff share, and the latest actual share (full method +
reproducer: `tariff-etr-adj/code/diagnostics/electronics_transition_probe.R` →
`results/tables/electronics_transition_probe.csv`).

| source region | 2024 share | GTAP predicted | latest actual | what happened |
|---|---|---|---|---|
| **China** | 0.227 | 0.198 (mild ↓) | **0.035** | collapsed — *more* than GTAP predicted |
| **ROW** (Vietnam, Taiwan, Malaysia, Thailand, India, …) | 0.428 | 0.199 | **0.639** | **surged** |
| EU | 0.067 | 0.118 (↑) | 0.045 | fell |
| Japan | 0.024 | 0.056 (↑) | 0.014 | fell |
| Canada | 0.014 | 0.029 (↑) | 0.008 | fell |
| UK | 0.008 | 0.025 (↑) | 0.005 | fell |
| other-FTA (incl. Korea) | 0.066 | 0.142 (↑) | 0.071 | flat |
| Mexico | 0.166 | 0.234 (↑) | 0.183 | stalled |

Two facts together are the puzzle:

1. **The China exodus is real and huge** — electronics sourcing moved hard away
   from China (0.227 → 0.035). So electronics clearly *are* meaningfully tariffed
   for China (consistent with §301 + the China IEEPA component). This is **not** a
   case of "electronics untaxed, nothing moved."
2. **The displaced volume went to ROW (low-cost Asia), not to GTAP's predicted
   high-income partners.** GTAP routed China's lost share to the EU/Japan/Korea/
   UK/Canada; in reality those all *lost or held* share and ROW absorbed nearly
   all of it.

GTAP routes diversion by **relative** post-tariff prices across suppliers. For it
to send electronics to advanced partners when reality sent them to ROW, the
*cross-partner electronics rate structure we gave it* would have to make advanced
partners look relatively cheap. That is exactly what a mis-applied reciprocal
schedule on electronics would do.

## Why we suspect the exclusion specifically

Our understanding (please verify — you are the authority on the rate build):
around **2025-04-11/12**, CBP guidance excluded a set of electronics —
smartphones, laptops, automatic data-processing machines, semiconductors, memory,
flat-panel displays — from the **reciprocal** tariffs, via HTS subheadings listed
under heading **9903.01.32** (≈20 codes incl. 8471, 8517.13.00, 8517.62.00,
8523.51, 8524, 8528.52, 8541, 8542). Those goods remained subject to the
**China-specific** measures (§301 and the 20% IEEPA/fentanyl component) and the
pending **§232 semiconductor** investigation — but **not** the country-varying
reciprocal rates.

If the tracker applies the reciprocal schedule to these electronics codes:
- China electronics rate would be roughly **right** (the China-specific stack
  dominates anyway — hence the real, large exodus), but
- **non-China** electronics rates would be **overstated and differentiated by the
  reciprocal schedule** (e.g. EU/Japan/Vietnam each get their reciprocal rate),
  giving GTAP a false relative-price map that routes diversion to the wrong
  partners.

That single specification choice would reproduce the observed pattern: a correct
China exodus, but to the wrong destinations.

## What would help us

1. **Confirm whether the electronics reciprocal exclusion is in the rate build**,
   and the exact (HS10 set, country scope, effective dates) it covers.
2. If it is applied: a pointer to the codes/heading so we can confirm our
   crosswalk (`hs10_gtap_crosswalk.csv` → `ele`) lines up with it.
3. If it is **not** applied (or only partially): that's likely our answer — we'd
   treat the current electronics shock as overstated for non-China partners and
   flag the affected `ele` cells, rather than charging the gap to GTAP's
   elasticities.

## Honest caveat

This may still be a GTAP-side issue — its Armington structure may simply
over-route diversion to large incumbent suppliers regardless of rates. We are
**not** asserting a tracker error; we are asking to rule out the rate
specification first, because it's the cheaper and more likely explanation given
the China-correct / destination-wrong signature. Either way, knowing the
exclusion's exact treatment lets us decide whether to (a) fix the shock inputs or
(b) attribute the miss to GTAP (our α `between`/`within` β<1 question,
`docs/open_questions.md` #12).
