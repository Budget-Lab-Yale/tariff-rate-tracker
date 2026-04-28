# Baseline Review — `rate_timeseries.rds`, 2026-04-22

Audit of the current baseline and cross-check against the April 2, 2026 Section 232 proclamation ("Strengthening Actions Taken to Adjust Imports of Aluminum, Steel, And Copper into the United States", effective 2026-04-06). Reviewer: Claude. Method: loaded individual snapshots (composite RDS is 1.27 GB and exceeds available RAM), compared rate-column summaries across rev_3 → rev_5, inspected `ch99_2026_rev_5.rds`, read the relevant code paths, cross-referenced the White & Case / JDSupra summary of the proclamation.

## Update (2026-04-22 17:40)

This memo describes the pre-fix baseline state. Since the initial review:

- The exporter-country Russia fix has been landed in source via `section_232_annexes.country_surcharges` in `config/policy_params.yaml` and a post-annex `pmax()` override in `src/06_calculate_rates.R`.
- The refreshed standalone `data/timeseries/snapshot_2026_rev_5.rds` now encodes the direct Russia exporter-country rule correctly. Spot-check: Russia chapter-76 rows in Annex I-A/I-B/III now have `rate_232 = 2.0`.
- The remaining publication issue is artifact sync. `rate_timeseries.rds` and `metadata.rds` still need to be regenerated from the refreshed rev_5 snapshot.
- The broader proclamation branch for non-Russia exporters with Russian smelt/cast provenance is still outside current repo data capacity and remains unmodeled.

## 1. Baseline file state

- Path: `data/timeseries/rate_timeseries.rds`
- Size: 1,272,838,881 bytes (1.27 GB)
- Last modified: 2026-04-22 13:00:10
- `metadata.rds`: 39 revisions, 184,978,080 rows, scenario = baseline
- Snapshots composing the file were built 12:01 – 12:42 on 2026-04-22
- HEAD commit `0338405` (auto-deal hardening + aluminum-derivative field rename) landed at 12:43 — **the baseline is one commit behind HEAD**. The rename is symmetric in parser + consumer, so numbers are unaffected, but the artifact does not reflect current source. Rebuild to sync.

## 2. Findings summary

| # | Finding | Affected rev | Severity | Status |
|---|---|---|---|---|
| 1 | Snapshots predate HEAD by one commit (field rename) | all | minor | numbers unaffected |
| 2 | IEEPA reciprocal + fentanyl zeroed from rev_4 | rev_4, rev_5 | — | **intentional** (SCOTUS ruling) |
| 3 | `metal_share = 1.0` everywhere; per-type shares = 0; `deriv_type` all NA | rev_5 | high | arrived at through wrong code path; see §5 |
| 4 | Russia aluminum 200% surcharge missing from published artifacts | rev_5 | **bug** | source fixed; standalone rev_5 snapshot refreshed; composite artifact still stale |
| 5 | Annex-2 products: 480 rows with `rate_232 = 0.25` | rev_5 | — | **not a bug** — all 480 are semi products; intentional per semi post-stacking override (§6) |
| 6 | No `9903.78.xx` or `9903.81.89-93` or `9903.85.04/07/08` codes in rev_5 ch99 | rev_5 | — | matches policy (annex supersedes) |
| 7 | UK reduced rates (25% I-A, 15% I-B) applying correctly to UK steel/aluminum | rev_5 | — | working |
| 8 | Copper (ch 74) assigned to annex_1a at 50% across all rows | rev_5 | — | working |

Row counts, rev_5 snapshot (4,765,440 rows total):

- `rate_232 > 0`: 675,840 — max 0.50 in the pre-refresh baseline; refreshed standalone `snapshot_2026_rev_5.rds` now restores `rate_232 = 2.0` for in-scope Russia aluminum rows
- `rate_ieepa_recip > 0`: 0 — expected under `ieepa_invalidation_date: '2026-02-24'`
- `rate_ieepa_fent > 0`: 0 — same
- `rate_s122 > 0`: 4,065,201
- `metal_share < 1`: 0 (rev_3/4 had ~510k–515k derivatives scaled below 1)
- `deriv_type` non-NA: 0 (rev_4 had 256,080)
- `s232_annex` non-NA: 691,440 (annex_1a=313,680; annex_1b=262,560; annex_2=87,840; annex_3=26,880)

## 3. Not a bug: IEEPA zeroing in rev_4+

`config/policy_params.yaml:524` — `ieepa_invalidation_date: '2026-02-24'` (SCOTUS *Learning Resources v. Trump*) — zeroes both `rate_ieepa_recip` and `rate_ieepa_fent` for all revisions on or after the SCOTUS implementation date. Section 122 (`rate_s122 = 10%`) replaces the blanket IEEPA surcharge within the 150-day window (expiry 2026-07-23). Everything after rev_3 shows the expected pattern.

## 4. Root cause: why rev_5 loses `deriv_type` and per-type shares

`apply_232_derivatives()` (`src/06_calculate_rates.R:342-347`) gates the entire derivative block on the presence of the pre-annex Ch99 codes:

```r
alum_deriv_ch99  <- c('9903.85.04', '9903.85.07', '9903.85.08')
steel_deriv_ch99 <- c('9903.81.89', '9903.81.90', '9903.81.91', '9903.81.93')
has_alum_deriv   <- any(ch99_data$ch99_code %in% alum_deriv_ch99)
has_steel_deriv  <- any(ch99_data$ch99_code %in% steel_deriv_ch99)
```

Verified against `ch99_2026_rev_5.rds` (486 rows): all seven codes are absent. The April 2026 proclamation replaced them with the annex CSV. With `has_alum_deriv = has_steel_deriv = FALSE`, the matching block is skipped. `deriv_matched` stays `character(0)`. `deriv_type` stays NA.

`load_metal_content()` (`src/data_loaders.R:400-432`) is called unconditionally on line 450, but with `derivative_hts10 = character(0)`:

```r
is_derivative <- result$hts10 %in% derivative_hts10
if (sum(is_derivative) == 0) {
  message('  Metal content: no derivative products to adjust')
  return(result)
}
```

The short-circuit returns the zero-initialised template — `metal_share = 1.0`, `steel_share = aluminum_share = copper_share = other_metal_share = 0` — for every HTS10. That's exactly what the snapshot carries.

Step 5c (annex override, `src/06_calculate_rates.R:1780-1886`) then correctly populates `s232_annex` and reassigns `rate_232` by tier, but **it does not backfill `deriv_type` or per-type shares**. Under the old regime these columns were load-bearing in stacking; under the new regime they are semantically obsolete (§5), but downstream code that still reads them (`compute_nonmetal_share()`, export paths, exports to ETRs config) sees a silently-different data shape than it saw in rev_3/rev_4.

## 5. Policy reconciliation — April 6, 2026 proclamation

From the proclamation (via White & Case / JDSupra):

### Annex structure
- **Annex I-A — 50% ad valorem on full customs value.** "Articles made entirely or almost entirely of aluminum, steel, or copper." Covers HTSUS chapters 72/73, 76, 74.
- **Annex I-B — 25% ad valorem on full customs value.** Derivative articles of steel and aluminum, and copper articles not almost entirely copper.
- **Annex II — removed from Section 232 scope.** Products revert to their underlying MFN + Section 122 (10% blanket through 2026-07-23).
- **Annex III — temporary reduced rates.** Higher of 15% or MFN; 10% or MFN if US-origin metal inputs. Expires 2027-12-31; products then roll to Annex I-B (25%).
- **Annex IV — referenced but not detailed in the summary material.** Proclamation text needed.

### Key departure from prior regime
> "Tariffs now apply to the full customs value of the imported product, including derivative products. The prior system splitting value between metal and non-metal content is eliminated — derivatives no longer pay tariffs only on metal input value."

**This reframes Finding #3 from the earlier review.** The fact that `metal_share = 1.0` for all rev_5 rows is *semantically correct under the new policy* — full-value taxation is exactly what the proclamation mandates. But the tracker arrives at that outcome by accident (the derivative-matching gate misses, so the metal-content join degenerates), not by design. And it loses `deriv_type` in the process, which some downstream paths may still expect.

`todo.md:39` confirms the tracker team already handled this: "Full-value stacking fix: `nonmetal_share=0` for annex products (2026-04-13)" — `compute_nonmetal_share()` returns 0 for annex-era products so other authorities (Section 122, etc.) apply to full value. Consistent with policy.

### Country-specific treatment
- **Russia:** "Aluminum articles/derivatives (Annex I-A, I-B, III) remain subject to the 200% tariff established in Proclamation 10522 of February 24, 2023" if Russian-origin or containing Russian primary aluminum.
  - Current source: fixed for the direct exporter-country branch. The tracker now applies a post-annex `country_surcharges` override for `country == '4621'` on aluminum Annex I-A/I-B/III rows, using `pmax(rate_232, 2.0)` after annex tiering. A refreshed standalone `snapshot_2026_rev_5.rds` confirms the direct Russia branch is back at 200%.
  - Remaining gap: the proclamation also covers non-Russia exporters when the aluminum was smelted or cast in Russia. The repo does not currently ingest shipment-level provenance fields, so that branch remains unmodeled.
- **United Kingdom:** Annex I-A → 25%, Annex I-B → 15%; requires "smelted or most recently cast in the UK" (aluminum) or "melted and poured in the UK" (steel).
  - Tracker today: UK annex_1a rows split 1,171 @ 25% + 136 @ 50%; annex_1b split 80 @ 15% + 1,014 @ 25%. The 136/1,014 residuals at the non-UK rate are UK rows on chapters *outside* `c('72','73','76')` — primarily copper (ch 74). That matches the proclamation's carve-out (`uk_applies_to: ['steel', 'aluminum']` — no UK reduction for copper). **Correctly implemented**, but the 95%-qualifying-content condition is approximated (see `todo.md:24`).
- **EU, Canada, Mexico, Japan, South Korea:** Civil aircraft and parts exempt under RTAs. Not traced here.

### Exemptions (proclamation language)
- **US-origin metal inputs** — reduced to 10% (vs prior full exemption). `us_origin_metal` config exists at `policy_params.yaml:247` with `aggregate_share: 0.0` — exemption infrastructure present but disabled pending calibration.
- **De minimis weight** — aggregate weight of steel/aluminum/copper inputs < 15% of total weight; applies outside chapters 72/73/74/76. `de_minimis_weight` config exists with `aggregate_share: 0.0` — disabled.
- **Motorcycle parts** — HTSUS 84/85/87 parts for motorcycle manufacturing, fully exempt. `motorcycle_parts` config exists with `aggregate_share: 0.0` — disabled.
- **HTSUS 9802.00.60** — "duties assessed based on full customs value of the article" (was on non-metal value). Not traced.

### Stacking
- "Tariffs do not stack with each other" — products covered under multiple Section 232 actions pay only one applicable tariff. Tracker's existing `pmax`-style heading aggregation handles this for intra-232; verify no path sums multiple 232 contributions.
- 232 still stacks with IEEPA / Section 122 / Section 301 per the proclamation (not excluded). In rev_5 IEEPA is zeroed (SCOTUS); Section 122 still applies; 301 still applies to China.

### Dates
- Effective 2026-04-06 12:01 EDT. No in-transit exception.
- Annex III sunset 2028-01-01 → reclassified to Annex I-B (tracker config uses 2027-12-31 sunset date — matches proclamation "through December 31, 2027").

## 6. Action items (priority order)

### Must-fix before next publication
1. **Rebuild and republish composite artifacts from the refreshed rev_5 snapshot.** The direct exporter-country Russia fix is now landed in source and present in `snapshot_2026_rev_5.rds`, but `rate_timeseries.rds` and `metadata.rds` need to be regenerated so published outputs match the corrected source.

2. ~~Investigate the 480 annex_2 rows with `rate_232 = 0.25`.~~ **Resolved as not-a-bug.** Verified: all 480 rows are semi HTS10s (10 prefixes under 8471.50/8471.80/8473.30 × 48 annex-II-classified pair slots). The semi post-stacking override at `src/06_calculate_rates.R:2275-2298` intentionally restores the 25% semi heading rate after the annex classification, per Note 39(a): "semi articles are not subject to 232 aluminum/steel derivative duties, and the April 2026 annex restructuring doesn't re-scope them." Zero non-semi products leak into annex_2 at non-zero rates. Could be tightened with an explicit test fixture asserting semi-only leakage (§6, item 5).

### Should-fix soon (policy fidelity)
3. **Document that `deriv_type` and per-type shares are intentionally stale in annex-era revisions.** Either:
   - Add a comment in `apply_232_derivatives()` noting that annex-era revisions use full-value taxation and therefore skip per-type scaling by design, OR
   - Have step 5c assign `deriv_type = 'annex_1a'` / `'annex_1b'` / etc. as a pseudo-tag so downstream code that groups on `deriv_type` sees a non-NA sentinel.
   This is a clarity issue, not a numbers issue, but an outside reader of the snapshot cannot tell whether the NAs are correct-by-policy or a bug without reading the code.

4. **Calibrate the three `aggregate_share: 0.0` exemptions.** `us_origin_metal`, `de_minimis_weight`, `motorcycle_parts` — each undercounts the effective exempt share. Calibration depends on external data (BEA use table or survey-based shares). Acceptable as upper-bound-on-tariff-revenue for now, but flag in `docs/assumptions.md`.

5. **Verify Annex IV handling.** The proclamation has an Annex IV that the available summary materials don't describe; the annex CSV may or may not include it. Check `docs/s232/Metals-ANNEXES-I-A-I-B-II-III-IV.pdf` for the list and ensure `resources/s232_annex_products.csv` is complete.
6. **Decide whether to model the Russian smelt/cast provenance branch.** That clause is legally part of the April 2026 rule, but it cannot be recovered from the repo's current aggregate HTS10 × exporter-country inputs. If left out, document the repo as exporter-country accurate rather than fully provenance accurate.

### Lower priority
7. **95% UK qualifying-content condition** and dynamic Ch99 parsing for annex classification — already tracked in `todo.md` under "Modeling gaps" and "Dynamic Ch99 parsing."

## 7. Reference materials

- White & Case: https://www.whitecase.com/insight-alert/united-states-modifies-steel-aluminum-and-copper-section-232-tariffs (HTTP 403 via WebFetch)
- JDSupra mirror: https://www.jdsupra.com/legalnews/united-states-modifies-steel-aluminum-3015669/
- White House proclamation: https://www.whitehouse.gov/presidential-actions/2026/04/strengthening-actions-taken-to-adjust-imports-of-aluminum-steel-and-copper-into-the-united-states/
- In-repo: `docs/s232/Metals-ANNEXES-I-A-I-B-II-III-IV.pdf`, `docs/s232/s232_metals_update_note.pdf` (SGEPT), `docs/s232/annexes_text.txt`
