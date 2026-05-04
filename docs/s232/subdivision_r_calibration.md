# Subdivision (r) auto-parts certification & FTA exemption

**Status**: code landed dormant 2026-05-02 / 2026-05-03 (`certified_share = 0`, `fta_exempt_shares = {EU: 0, JP: 0, KR: 0}`); calibration pending.

**Scope**: post-April 6, 2026 §232 metals annex regime, EU / Japan / Korea auto-parts trade in chapter 87 outside the standard subdivision (g) auto-parts list.

**Affected code**:
- `src/06_calculate_rates.R` step 5d (within the post-annex block, after step 5c annex override).
- `config/policy_params.yaml` `auto_parts_subdivision_r` block.
- `resources/s232_subdivision_r_products.csv` (8 prefixes, rebuild via `scripts/build_subdivision_r_products.R`).
- `tests/test_rate_calculation.R` Test 13 (7 cases).

---

## 1. Legal basis

US Note 33 to subchapter III of Chapter 99 (rev_6 ch99 PDF, plain-text dump at `data/us_notes/chapter99_2026_rev_6.txt` lines 35395–35900) defines the §232 auto-parts regime. The relevant subdivisions:

| Subdiv | Heading(s) | Country scope | Product scope | Rate |
|---|---|---|---|---|
| (g) | 9903.94.05, .42, .43, .52, .53, .62, .63 | All countries (.05); JP / EU / KR (.42–.63) | Fixed list of HS6/HS8 prefixes (4009.12.0020 … 9401.20.00) | 25% blanket; 15% floor for JP / EU / KR deal countries |
| (l) | 9903.94.42, .43 | Japan | Subdivision (g) products | Passthrough if base ≥ 15% (.42), 15% floor if base < 15% (.43) |
| (o) | 9903.94.52, .53 | EU | Subdivision (g) products | Passthrough / 15% floor |
| (t) | 9903.94.62, .63 | Korea | Subdivision (g) products | Passthrough / 15% floor |
| (p) | 9903.94.07 | All countries | Auto parts NOT in (g), certified for US production | 25% |
| (r) | 9903.94.44, .45, .54, .55, .64, .65 | EU / Japan / Korea | Auto parts NOT in (g), NOT in chapters 72/73/76, NOT in Note 38(i) MHD parts, certified for US production | Passthrough (.44/.54/.64) / 15% floor (.45/.55/.65) |

Subdivisions (g), (l), (o), (t) cover the *standard auto-parts list*. Subdivision (r) is a *certification-based extension* that opens the deal to additional parts that weren't enumerated in (g), provided the importer certifies they're for US auto production or repair.

### 1.1 The (r)(1) metals carve-out

Lines 35853–35858:

> All antidumping, countervailing, or other duties and charges applicable to such goods shall continue to be imposed in addition to the duty in headings 9903.94.44, 9903.94.45, 9903.94.54, 9903.94.55, 9903.94.64, and 9903.94.65, **except that articles under these headings shall not be subject to**:
> (1) the additional duties imposed on entries of articles of aluminum, of steel, or of copper or derivative aluminum or steel articles provided for in headings **9903.82.02 and 9903.82.04–9903.82.19**.

Headings 9903.82.02 and 9903.82.04–.19 are the new annex codes implementing the April 2026 metals proclamation (US Note 16; verified at line 15649 of the same dump). So a part entered under 9903.94.45 (EU certified) is explicitly exempt from the metals annex it would otherwise fall under as a steel-content auto part.

### 1.2 The FTA-qualifying carve-out

Lines 35836–35837 (also in subdivision (r)):

> shall be collected in addition to any special rate of duty otherwise applicable under the appropriate tariff subheading, **except for goods qualifying under Executive Order 14345 of September 4, 2025 (Implementing the United States-Japan Agreement) or the United States-Korea Free Trade Agreement.**

So FTA-qualifying KR / JP imports under 9903.94.44–.65 pay neither the additional duty (passthrough or 15% floor) nor the metals annex (via the (r)(1) carve-out). They pay only the underlying FTA-special tariff (typically 0% under KORUS, 0% under EO 14345 for in-scope items).

**Important scoping**: this FTA carve-out clause is in subdivision (r), not in (l) / (o) / (t). KR / JP imports of subdivision (g) products that *also* qualify for KORUS / EO 14345 still pay the 9903.94.42–.63 additional duty per the literal legal text — the FTA exemption is specific to the certified-for-production pathway.

---

## 2. The bug

The April 2026 metals proclamation pulled additional ch87 products into annex_1b at 25%. Step 5c of `calculate_rates_for_revision()` applies the annex_1b rate to any product in `s232_annex_products.csv` with `s232_annex == 'annex_1b'` that isn't in `heading_program_products`. Since subdivision (r) products are by definition NOT in our heading product lists (auto_parts heading list reflects subdivision (g)), they fall through and get 25%.

For EU / JP / KR specifically, this is wrong. Per (r), if the importer certifies the part for US production, the rate is 15% floor (or 0 if FTA-qualifying), and the metals annex is suppressed.

### 2.1 Audit at rev_6 (`scripts/check_auto_floor_annex.R`)

Looking at the `snapshot_2026_rev_6.rds` file:

| Country | annex_1b ch87 rows NOT in subdivision (g) | rate_232 | n distinct HTS10 |
|---|---|---|---|
| EU 27 | 2,862 | 0.25 (annex_1b) | 106 |
| Japan | 106 | 0.25 | 106 |
| Korea | 106 | 0.25 | 106 |

Per the legal text, none of these should be at a flat 0.25:

| Subgroup | Correct rate per Note 33(r) |
|---|---|
| FTA-qualifying KR / JP | 0 (deal exempt + metals annex exempt) |
| Non-FTA, certified for US production | pmax(0.15 - base_rate, 0) |
| Non-FTA, not certified | 0.25 (annex_1b) — current behavior, correct for this slice only |

### 2.2 Why DataWeb cannot directly resolve the split

USITC DataWeb's `rateProvisionCodes` filter is a 2-digit aggregate (`19 = Free HS Chapter 99`, `69 = Dutiable HS Chapter 99 duty reported`, etc.) — confirmed via `getRPCodesList`. There is no 9903.xx-line filter dimension. The closest signal is `extImportPrograms` (SPI codes), which give upper bounds on the FTA-qualifying share but cannot disambiguate the non-FTA slice between 9903.94.45 (certified, 15%) and 9903.82.04+ (annex, 25%).

**Probed signals (`src/download_subdivision_r_share.R`, 2025 data, ch87 customs value, $M):**

| Country | Total ch87 | Subdiv-r | SPI claimed (subdiv-r) | SPI utilization |
|---|---|---|---|---|
| Japan | 45,906 | 691 | ≈ 0 (SPI=JP) | ≈ 0% |
| Korea | 36,876 | 672 | 577 (SPI=KR) | 85.9% |
| Germany | 28,363 | 358 | n/a (no EU SPI) | n/a |
| Italy | 3,669 | 105 | n/a | n/a |

The Japan number reflects that EO 14345 / SPI=JP is mostly a digital-trade agreement; importers don't claim it on autos. The Korea number is the KORUS utilization rate on these specific HTS10s, which is an upper bound on `fta_exempt_shares.KR` (since not every KORUS-claimed import will additionally certify under (r)). EU has no parallel SPI.

---

## 3. The model

### 3.1 Eligible product set

`resources/s232_subdivision_r_products.csv` (rebuilt via `scripts/build_subdivision_r_products.R`):

- HS4 ∈ {8706, 8707, 8708} — chassis / bodies / parts of motor vehicles. Excludes 8701–8705 / 8709 (vehicles, not parts) and 8716 (trailers, which are not parts of passenger vehicles or light trucks per the proclamation scope).
- Tagged `annex == '1b'` in `s232_annex_products.csv` — so currently bears 25% under step 5c.
- NOT in `s232_auto_parts.txt` (= subdivision (g) HS prefixes).
- NOT in `s232_mhd_parts.txt` (= Note 38(i) MHD parts, excluded by Note 33(r)(iii)).

At rev_6, this resolves to 8 prefixes:

```
87060030  87089210  87089250  87089260  87089275
87089315  87089330  87089981
```

(Chassis + a handful of muffler / clutch / "other parts" 8708 codes that the April 2026 annex CSV swept into 1b but that subdivision (g) doesn't enumerate.)

The list will grow whenever the annex CSV adds ch87 1b prefixes that aren't in subdivision (g) — rerun `build_subdivision_r_products.R` after annex updates.

### 3.2 Three-way mix per import

For products in this set + countries in {EU 27, Japan, Korea}, step 5d applies:

```
rate_232 = fta_share × 0
         + (1 - fta_share) × [ certified_share × pmax(floor_rate - base_rate, 0)
                              + (1 - certified_share) × current_rate_232 ]
```

Where `current_rate_232` at this point in the pipeline is the post–step-5c value, i.e. the annex_1b 25%.

The three buckets correspond to:

1. **FTA-qualifying** (`fta_share`): KR imports under KORUS, JP imports under EO 14345. Both the deal duty AND the metals annex are exempt per Note 33(r) lines 35836-37 and (r)(1). `rate_232 = 0`; only `base_rate` (the FTA-special tariff) survives downstream.

2. **Non-FTA, certified for US production** (`(1 - fta_share) × certified_share`): pays the 15% floor under 9903.94.45 / .55 / .65. Per (r)(1), still exempt from the metals annex. `rate_232 = pmax(0.15 - base_rate, 0)`.

3. **Non-FTA, not certified** (`(1 - fta_share) × (1 - certified_share)`): falls through to the standard regime. The metals annex applies. `rate_232 = current_rate_232 = 0.25` (annex_1b).

### 3.3 What's NOT modeled here

- **IEEPA reciprocal stacking on certified parts**: Note 33(r) only carves certified parts out of 9903.82.x metals. IEEPA reciprocal (9903.02.x) is not exempted. But our existing `compute_nonmetal_share()` zeros `rate_ieepa_recip` on any product with `s232_annex != NA`, including post-step-5d certified parts. This matches how subdivision (g) products are stacked today (rate_232 = floor, rate_ieepa_recip = 0). If we revisit IEEPA stacking on (g), apply the same to (r).
- **The KORUS / EO 14345 exemption *outside* subdivision (r) certification**: A KR importer who claims KORUS but doesn't also certify under (r) still pays 25% annex_1b in our model. Whether KORUS itself should exempt from the metals annex independent of (r) is a separate legal question (open in `tariff_tracker_investigated_issues.md`).
- **Subdivision (g) IEEPA-floor double-counting**: For EU subdivision (g) products with metal_share = 1, `rate_232 = 12.5%` (deal floor) and `rate_ieepa_recip = 0` (zeroed by metals stacking) ⇒ total 12.5%, even though the legal text suggests both the auto deal floor and the IEEPA reciprocal floor independently apply. Pre-existing behavior, not specific to subdivision (r).

---

## 4. Calibration parameters

All in `config/policy_params.yaml` under `auto_parts_subdivision_r`.

| Parameter | Default | Plausible range | DataWeb upper bound (2025) |
|---|---|---|---|
| `certified_share` | 0.0 | 0.25–0.75 | undifferentiated by DataWeb |
| `fta_exempt_shares.EU` | 0.0 | structurally 0 | n/a (no EU FTA) |
| `fta_exempt_shares.JP` | 0.0 | likely near 0 | ≈ 0 (US-Japan deal not auto-scoped) |
| `fta_exempt_shares.KR` | 0.0 | 0.5–0.85 | 0.86 (SPI=KR utilization on subdiv-r ch87) |

`certified_share` applies uniformly to all three country groups (EU / JP / KR). `fta_exempt_shares` is per-country.

### 4.1 Calibration sources

- **CBP entry-summary line counts**: would directly answer the certified_share question, but CBP doesn't publish at 9903-line granularity. Probably FOIA.
- **Industry estimates**: MEMA (Motor & Equipment Manufacturers Association), Auto Care Association, SAFE (Securing America's Future Energy), or AAPC (American Automotive Policy Council) likely have aggregate certification data. SAFE's `docs/s232/s232_metals_update_note.pdf` is the existing reference for the April 2026 annex modeling.
- **CBP CSMS bulletins**: typically operational guidance, not aggregate stats. Worth checking for any utilization reports.
- **Sensitivity-range defaults**: for first-pass analysis, set `certified_share = 0.5` and `fta_exempt_shares.KR = 0.5` and run as an alternative scenario to bracket the impact (see `config/scenarios.yaml`).

---

## 5. Tests

`tests/test_rate_calculation.R` Test 13 covers:

1. Subdivision (r) products file exists and is non-empty (chapter 87, annex_1b only).
2. Default `certified_share = 0` (dormant).
3. Saved rev_6 snapshot still shows 25% on subdivision (r) HTS10s for KR (regression baseline confirms the fix is dormant).
4. Two-way blend math (`fta_share = 0`): synthetic check at base = 0, base = 2.5%, certified_share = 0.5 / 1.0.
5. FTA-exempt config defaults to no-op (all three shares = 0).
6. Three-way blend math: `fta = 1.0` zeros rate_232; `fta = 0.86, certified = 0.5, base = 0` ⇒ 0.028; mixed shares produce correct weighted average.
7. Saved rev_6 snapshot baseline still pre-fix (regression for both fixes being dormant by default).

Re-run with `Rscript tests/test_rate_calculation.R`. 83/83 passing as of 2026-05-03.

---

## 6. Audit script

`scripts/check_auto_floor_annex.R` (gitignored under `check_*.R` pattern) re-runs the rev_6 snapshot audit that originally surfaced the gap. Use it after rebuilding rev_6 with non-zero parameters to confirm the rate distributions move as expected.

Expected post-calibration distributions for EU subdiv-r (with `certified_share = 0.5`, `fta_exempt_shares.EU = 0`):

```
rate_232 = 0    × 0       (no FTA share)
         + 1.0  × [0.5 × pmax(0.15 - base, 0)
                   + 0.5 × 0.25]
        ≈ 0.0625 (base = 0)  to  0.1875 (base = 0)  depending on what "current_rate_232" is
```

In the typical case where `current_rate_232 = 0.25` (annex_1b) and `base ≈ 0`:

```
rate_232 = 0.5 × 0.15 + 0.5 × 0.25 = 0.20  (20%)
```

A drop from 25% to 20% on these 22 8708 HTS10s × 27 EU countries.

---

## 7. Alternative scenario: `subdivision_r_mid`

Added to the `--with-alternatives` rebuild block in `src/09_daily_series.R` (after the `dutyfree_nonzero` scenario). Sets:

```r
pp_subdiv_r$auto_parts_subdivision_r$certified_share <- 0.5
pp_subdiv_r$auto_parts_subdivision_r$fta_exempt_shares$KR <- 0.5
```

EU and JP `fta_exempt_shares` remain at 0 (EU has no carve-out, JP utilization signal near zero). The scenario is a sensitivity bracket — not a calibrated estimate. Rebuild output lands in `output/alternative/*subdivision_r_mid*.csv`.

This is a *rebuild* alternative (re-runs `calculate_rates_for_revision()` with overridden policy_params), not a post-build patch. Triggered by `Rscript src/00_build_timeseries.R --with-alternatives` or the equivalent invocation in `09_daily_series.R`.

## 8. Future work

- **Calibrate parameters** from one of the sources in §4.1.
- **Bracket the impact** by running `--with-alternatives` and comparing `subdivision_r_mid` against the main timeseries.
- **Generalize FTA exemption beyond subdivision (r)**: scope whether KORUS / EO 14345 should also exempt from the metals annex when the importer doesn't claim subdivision (r) certification. Currently flagged as open in `tariff_tracker_investigated_issues.md`.
- **Expand subdivision (r) eligible set**: the April 2026 annex CSV is static at rev_6. As future revisions add more ch87 prefixes to annex_1b, rerun `build_subdivision_r_products.R` to refresh the eligible list.
