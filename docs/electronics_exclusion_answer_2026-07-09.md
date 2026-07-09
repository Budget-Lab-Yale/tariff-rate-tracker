# Answer: yes, the tracker applies the electronics reciprocal exclusion (HTS 9903.01.32)

**From:** tariff-rate-tracker (the rate build)
**To:** tariff-etr-adj (eta/alpha calibration)
**Date:** 2026-07-09
**Re:** `docs/electronics_exclusion_query_2026-06-20.md`
**Status:** confirmed from code + resource data — this is NOT a tracker mis-specification.

## TL;DR

The April-2025 reciprocal-tariff electronics carve-out (heading 9903.01.32:
smartphones, laptops/ADP machines, semiconductors, memory, flat-panel modules)
**is applied in the rate build.** It:

- zeros **only the reciprocal layer** (`rate_ieepa_recip`) — the country-varying
  "Liberation Day" schedule;
- leaves the **China-specific stack intact** — §301, the 20% fentanyl/IEEPA
  component, and the pending §232 semiconductor slot all still apply;
- is **universal across all reciprocal partners** (not China-scoped);
- is **date-windowed** from **2025-04-05** (the retroactive memo date).

So your relative-price map is **not** distorted by a missing carve-out: for
non-China partners (EU/JP/VN/…) these electronics already carry **zero
reciprocal rate** in the tracker. The "China-correct, destination-wrong"
electronics diversion pattern you observed is therefore **not** explained by the
tracker over-applying the reciprocal schedule to electronics. It points back to
the GTAP-side Armington/α question (your `open_questions.md` #12), OR to the two
crosswalk gaps below — please check those before charging the miss to
elasticities.

## The exact treatment (your three asks)

### 1. Is it applied, and over what (HS10 set, country scope, dates)?

**Yes.** The exempt HS10 list is `resources/ieepa_exempt_products.csv` in the
tracker (3,256 rows; columns `hts10, effective_date_start, effective_date_end`),
built by `scripts/build_annex_ii_dates.R` (it scrapes each revision's chapter-99
PDF, anchors on the `9903.01.32` sentence, and walks the note 2(v)(iii)(a)
enumeration). It is applied in `src/pipeline/06_calculate_rates.R:1912-1934`:

```r
is_universally_exempt = hts10 %in% ieepa_exempt_products,   # no country predicate
exempt_active        = is_universally_exempt & (ieepa_exempt_scope == 'all' | ...),
rate_ieepa_recip = case_when(
  ...
  ieepa_type == 'surcharge' ~ if_else(exempt_active, 0, ieepa_country_rate - country_eo_rate) + ...,
  ieepa_type == 'floor' & exempt_active ~ 0,
  ...)
```

- **Country scope:** universal — `is_universally_exempt` has no country term, so
  every reciprocal partner gets `rate_ieepa_recip = 0` on these codes.
- **Dates:** windowed via `effective_date_start` (`src/model/data_loaders.R:179-183`).
  The electronics-memo cohort is stamped **2025-04-05** (retroactive; CBP guidance
  published ~Apr 11). Semiconductor headings 8541/8542 carry `effective_date_start
  = NA` (exempt from reciprocal inception — equivalent, since reciprocal didn't
  exist before Apr 5).
- **Layer scope:** only `rate_ieepa_recip`. §301 (`rate_301`), the China 20%
  fentanyl/IEEPA (`rate_ieepa_fent`), and §232 stack independently and are
  untouched — matching the legal treatment.

### 2. The code/date list, for your crosswalk check

Attached: **`resources/electronics_reciprocal_exempt_from_tracker.csv`** (in this
repo, alongside `hs10_gtap_crosswalk.csv`) — the 133 exempt HS10s under the
electronics headings you named, with their effective dates and the tracker's
current GTAP mapping. Columns:
`hts10, effective_date_start, effective_date_end, gtap_code, reciprocal_exempt,
china_301_still_applies, china_fentanyl_ieepa_still_applies`.

Coverage of your expected headings:

| heading | codes | start |
|---|---|---|
| 8471 (ADP machines) | 34 | 2025-04-05 |
| 8473 (ADP parts) | 5 | 2025-04-05 |
| 8486 (semi-mfg equipment) | 7 | 2025-04-05 |
| 8517.13 / 8517.62 (phones) | 5 | 2025-04-05 |
| 8523.51 (SSD/flash) | 1 | 2025-04-05 |
| 8524 (flat-panel/media modules) | 8 | 2025-04-05 |
| 8528.52 (monitors) | 1 | 2025-04-05 |
| 8541 (diodes/semiconductors) | 36 | NA (from inception) |
| 8542 (integrated circuits) | 36 | NA (from inception) |

### 3. Two crosswalk gaps that WILL bite a `ele`-only view

If your `hs10_gtap_crosswalk.csv → ele` filter is how you decide which exempt
codes touch the electronics sector, note:

1. **15 exempt codes map to GTAP `OME`, not `ele`** — the 7× **8486**
   (semiconductor-manufacturing equipment) and 8× **8524** (flat-panel/recorded-
   media modules). An `ele`-only join silently drops these exemptions. Whether
   that matters depends on whether your `ele` shock includes 8486/8524; if it
   does, you're double-missing them.
2. **25 of the 133 exempt HS10s have no row in the crosswalk at all** (mostly the
   `…0100`/parent statistical-header lines, e.g. 8471410100, 8517620000). They
   appear with a blank `gtap_code` in the attached CSV. If your shock is built at
   HS6/leaf level these are covered elsewhere, but worth confirming.

## How to reproduce the impact yourself

The exemption is materialized inside the rate build (no standalone export). Two
routes:
- **Source list:** the attached CSV already gives HS10 × date-window; country =
  all reciprocal partners.
- **Impact diff:** rebuild the tracker once with `ieepa_exempt_scope: 'all'`
  (default) and once with `'baseline_only'`; the per-(HS10, country, revision)
  difference in `rate_ieepa_recip` is exactly the set and magnitude of the Annex
  II exemption. (`config/policy_params.yaml:789-824` documents this toggle.)

## Bottom line

Rate specification is **correct and not the cause** of the electronics
destination miss for non-China partners. Recommend: (a) reconcile the two
crosswalk gaps above; (b) if the pattern survives that reconciliation, it is a
GTAP-side α/Armington question, not a tracker input to fix.

---
*Source-of-truth in the tracker repo: `resources/ieepa_exempt_products.csv`,
`src/pipeline/06_calculate_rates.R:1912-1934`, `scripts/build_annex_ii_dates.R`,
`docs/tracker_review_extreme_etas.md` §2.*
