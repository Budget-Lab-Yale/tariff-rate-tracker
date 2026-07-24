# §232 derivative list — HS8-truncation over-inclusion fix

## Summary

Commit `d39c270` ("Fix 232 derivative product classification: truncate HTS10
prefixes to HTS8") truncated **all** derivative-product prefixes in
`resources/s232_derivative_products.csv` from 10-digit to 8-digit, on the
rationale that statistical suffixes churn across HTS revisions.

For entries the Federal Register enumerated at the **full 8-digit subheading**,
that is correct. But for entries the FR notice (2025-15819, §232 Steel/Aluminum
Derivative Inclusions Process, eff. 2025-08-18) listed at a **specific 10-digit
statistical line**, HS8 truncation broadens coverage to the *entire* subheading.
`classify_s232_annex()` (`src/model/data_loaders.R`) then prefix-matches the HS8
and tags every 10-digit line under it as `annex_1b` @ 25%.

Poster child: FR 2025-15819 added **3004.90.9244** only (one pharmaceutical
line, ~$27M imports). Truncation to `30049092` swept the whole 3004.90.92
subheading — **$85.0B, 70 statistical lines** — into the 25% metals-derivative
duty. Switzerland ships **$12.0B** of 3004.90.92 but **$0** of the actual .9244
line, so ~100% of its pharma §232 was spurious (~5pp of its overall rate). This
was the entire Switzerland gap vs the GTA 24-July-2026 estimate (our 9.6% vs
their 4.6%).

## Audit

Comparing the pre-truncation file (`d39c270~1`, original FR granularity) against
the current HTS10 universe and 2024 import weights:

- **127 subheadings** were listed *only* via specific 10-digit lines (never a
  bare 8-digit entry) and were broadened by truncation.
- **Class A — real over-inclusion (121 subheadings, ~$155B spurious):** the
  FR-listed 10-digit line still exists in the current HTS, so restoring 10-digit
  granularity re-narrows coverage to exactly the FR scope. **Fixed.**
- **Class B — genuine suffix churn (6 subheadings, ~$5B):** the FR-listed
  suffix no longer exists; the current subheading has different/renumbered
  suffixes and remapping is ambiguous without FR-description matching. **Left at
  HS8** as a documented proxy — this is the narrow case d39c270 legitimately
  targeted. (hs8: 84129090, 84834050, 73082000, 83099000, 85016401, 86073010.)

Top Class A over-inclusions by spurious import value ($B):

| HS8 | subheading imports | spurious | % | lines | FR lines kept |
|-----|-----|-----|-----|-----|-----|
| 30049092 (pharma) | 85.0 | 85.0 | 100 | 70 | 2 |
| 87082951 (vehicle parts) | 18.3 | 18.3 | 100 | 4 | 1 |
| 88073000 (aircraft parts) | 13.6 | 10.4 | 77 | 3 | 1 |
| 87012100 (tractors) | 9.7 | 9.7 | 100 | 3 | 1 |
| 21069099 (food preps) | 6.3 | 6.3 | 100 | 13 | 2 |
| 84798995 (machines) | 6.3 | 6.3 | 100 | 8 | 1 |
| 84139190 (pump parts) | 2.9 | 2.9 | 100 | 10 | 3 |
| 27101930 (lubricating oil) | 2.9 | 2.9 | 100 | 7 | 2 |

## Fix

`resources/s232_derivative_products.csv`: for the 121 Class A subheadings,
restored the original FR-accurate 10-digit prefixes (from `d39c270~1`); all
genuinely-8-digit entries and the 6 Class B churn subheadings are unchanged.
Row count 568 → 616 (439 eight-digit + 177 ten-digit).

Verified with `classify_s232_annex()`: `3004909244 → annex_1b` (kept),
`3004909216/17 → NA` (dropped). Preflight and annex-parser tests pass.

## Expected build impact (from the 2026-07-24 panel, before rebuild)

**Actual (build 2026-07-24-08): −0.8pp overall.** The −0.98pp below was a
static estimate (removed base × its §232 rate); it ignores displacement — the
freed base gets backfilled by IEEPA-reciprocal/§122 on the full customs value
once §232 no longer claims (the metal share of) those rows, which claws back
~0.2pp.

- **Overall US effective rate: ≈ −0.98pp** (removes ~$145B of spurious §232
  base carrying an avg 21%).
- Largest per-country reductions (pp): Hungary −8.9, Switzerland −5.3,
  Singapore −5.1, Belgium −4.1, Ireland −3.8, India −3.3, Israel −1.7,
  Italy −1.6, Spain −1.3, UK −1.2, Japan/France −0.8.
- These moves reconcile our pharma-heavy origins with the GTA 24-July estimate
  (e.g. Switzerland 9.6% → ~4.4% vs GTA 4.6%).

Golden-changing: requires a Slurm rebuild + golden re-freeze after review.
