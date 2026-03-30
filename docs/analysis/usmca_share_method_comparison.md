# USMCA Share Method Comparison

**Date:** 2026-03-29
**Purpose:** Evaluate three approaches for applying product-level USMCA utilization shares when computing effective tariff rates (ETRs) for Canada and Mexico. The goal is to select a baseline method and an alternative scenario.

## Background

USMCA-eligible products claimed under the agreement face reduced or zero tariffs. Rather than binary eligibility (S/S+ in HTS `special` field), we apply continuous product-level utilization shares from USITC DataWeb SPI data. Each tariff rate is scaled by `(1 - usmca_share)`, so a share of 0.85 means 85% of trade in that product is claimed under USMCA and only 15% faces the full tariff.

The 2025 data shows a **structural break in USMCA utilization** around mid-year: firms sharply increased claiming in response to new tariffs. This creates a tension between accuracy (reflecting time-varying behavior) and stability (avoiding noisy month-to-month swings in ETRs).

## Three Methods

### 1. 2025 Annual Average

A single set of product-level shares computed from full-year 2025 trade.

- **Pros:** Maximum product coverage (40,258 product-country pairs); no month-to-month jitter; simple.
- **Cons:** Blends two distinct regimes (low-claiming H1 and high-claiming H2). The annual average share (trade-weighted 0.676) doesn't represent either period accurately.

### 2. Raw Monthly

Each HTS revision uses the share file matching its effective month.

- **Pros:** Captures the behavioral shift in real time; most accurate representation of actual USMCA claiming in each period.
- **Cons:** Sharp 35.6pp jump in aggregate share from June to July. At the product level, 51% of product-country pairs are flagged as "noisy" (CV > 0.5 or spread > 0.3). Lumpy trade in individual months creates apparent volatility even when the underlying claiming pattern is stable.

### 3. Hybrid Rolling Average (Q1 average + 3-month rolling from April)

January--March use the Q1 average share (pooling trade across Jan/Feb/Mar). Starting in April --- when the tariff regime kicks in --- each month uses a rolling average of months `m`, `m-1`, `m-2` (available months only). This smooths the transition while still tracking the behavioral shift.

- **Pros:** Eliminates pre-tariff month-to-month noise; smooths the mid-year regime shift; converges to raw monthly by September; reduces product-level jitter by 27% (trade-weighted).
- **Cons:** Lags the true behavioral shift by ~2 months; slightly higher distance from annual average in early months (Q1 pooled differs from individual months).

## Comparison: Trade-Weighted Aggregate USMCA Share

| Month | Annual | Raw Monthly | Hybrid Rolling | Raw vs Annual | Hybrid vs Annual |
|------:|-------:|------------:|---------------:|--------------:|-----------------:|
|   Jan |  0.676 |       0.397 |          0.426 |       -0.279  |          -0.251  |
|   Feb |  0.676 |       0.403 |          0.426 |       -0.273  |          -0.251  |
|   Mar |  0.676 |       0.478 |          0.426 |       -0.199  |          -0.250  |
|   Apr |  0.676 |       0.500 |          0.461 |       -0.176  |          -0.215  |
|   May |  0.676 |       0.494 |          0.491 |       -0.182  |          -0.185  |
|   Jun |  0.676 |       0.500 |          0.498 |       -0.177  |          -0.178  |
|   Jul |  0.676 |       0.856 |          0.617 |       +0.180  |          -0.059  |
|   Aug |  0.676 |       0.850 |          0.733 |       +0.173  |          +0.057  |
|   Sep |  0.676 |       0.868 |          0.862 |       +0.192  |          +0.186  |
|   Oct |  0.676 |       0.880 |          0.868 |       +0.203  |          +0.192  |
|   Nov |  0.676 |       0.879 |          0.875 |       +0.203  |          +0.199  |
|   Dec |  0.676 |       0.876 |          0.876 |       +0.199  |          +0.200  |

## Month-to-Month Jitter (Aggregate Share)

| Transition | Raw Monthly | Hybrid Rolling |
|-----------:|------------:|---------------:|
|    Jan-Feb |       0.006 |          0.000 |
|    Feb-Mar |       0.075 |          0.000 |
|    Mar-Apr |       0.022 |          0.035 |
|    Apr-May |       0.006 |          0.030 |
|    May-Jun |       0.005 |          0.007 |
|  **Jun-Jul** | **0.356** |      **0.119** |
|    Jul-Aug |       0.006 |          0.116 |
|    Aug-Sep |       0.018 |          0.129 |
|    Sep-Oct |       0.012 |          0.006 |
|    Oct-Nov |       0.001 |          0.008 |
|    Nov-Dec |       0.003 |          0.001 |
| **Mean**   |   **0.046** |      **0.041** |
| **Max**    |   **0.356** |      **0.129** |

The hybrid rolling reduces the maximum single-month jump by **64%** (35.6pp to 12.9pp) at the cost of spreading the adjustment over three months (Jul--Sep each move ~12pp). By October the two series have converged.

## Product-Level Noise

|                            | Raw Monthly | Hybrid Rolling | Reduction |
|---------------------------:|------------:|---------------:|----------:|
| Trade-weighted mean |delta|  |      0.066 |          0.048 |     27.5% |
| Unweighted mean |delta|      |      0.153 |          0.100 |     34.6% |

## Coverage

Coverage is consistently high across all methods. Even in the sparsest month (August), monthly files cover **98.7%** of CA/MX trade by value. The ~25,000 products present in the annual file but absent in a given month account for only 0.4--1.3% of trade. These are products with no USMCA claims that month, correctly treated as having zero utilization.

| Month | Raw/Hybrid Coverage | Annual Coverage |
|------:|--------------------:|----------------:|
|   Jan |              99.4%  |          100.0% |
|   Apr |              99.2%  |          100.0% |
|   Jul |              99.1%  |          100.0% |
|   Aug |              98.7%  |          100.0% |
|   Oct |              99.5%  |          100.0% |
|   Dec |              99.2%  |          100.0% |

Coverage is **not a concern** for any method.

## Interpretation

The dominant feature in the monthly data is not noise --- it is a real structural break in USMCA utilization triggered by the April 2025 tariff regime. Firms responded by roughly doubling their USMCA claiming rates (trade-weighted share rising from ~0.40--0.50 in H1 to ~0.85--0.88 in H2). The annual average (0.676) is a blend of these two regimes and accurately represents neither.

Both the raw monthly and hybrid rolling approaches capture this behavioral shift. They differ only in timing: raw monthly shows it as a single sharp jump in July; the hybrid rolling spreads it across July--September. By Q4 2025 the two series are indistinguishable.

## Recommendation

| Role | Method | Rationale |
|------|--------|-----------|
| **Baseline** | H2 2025 average (Jul-Dec) | Reflects post-tariff steady-state utilization. Time-invariant across revisions, avoids monthly noise, and represents the regime firms are actually operating under. Trade-weighted share ~0.87 for both CA and MX. |
| **Alternative 1** | Hybrid rolling (Q1 avg + 3-month rolling from April) | Time-varying sensitivity: captures the transition from low to high utilization with smoothing. |
| **Alternative 2** | Raw monthly | Unsmoothed behavioral response. Bounds the timing of the USMCA utilization jump. |
| **Alternative 3** | 2025 annual average | Blends pre- and post-tariff regimes. Useful as a counterfactual or comparison with approaches that lack monthly data. |

The H2 average is the most defensible baseline because the post-tariff utilization pattern is the steady state going forward. Using H1 data (when utilization was low because tariffs hadn't yet been imposed) would understate the USMCA offset. The annual average (0.676) is a mix of two regimes and represents neither accurately.

## Implementation

The H2 average mode is implemented as `mode: 'h2_average'` in `config/policy_params.yaml` (default). The logic lives in `load_usmca_product_shares()` in `src/helpers.R` --- it loads months 7-12, averages per product-country pair, and returns a single time-invariant share table. Alternative scenarios (`usmca_annual`, `usmca_monthly`, `usmca_2024`, `usmca_dec2025`) are built automatically during `--with-alternatives` runs via `09_daily_series.R`.

Other available modes: `hybrid_rolling` (Q1 avg + 3-month rolling from April), `monthly` (raw per-month), `annual` (full-year average), `fixed_month` (single configured month).

## ETR Time Series Comparison

*To be populated after the next full pipeline run with `--with-alternatives`.* The comparison will show `weighted_etr` from `output/alternative/daily_overall_usmca_annual.csv`, `daily_overall_usmca_monthly.csv`, and the baseline (H2 average) from `output/daily/daily_by_authority.csv`.

Key questions to answer:
- How large is the ETR difference between methods at key policy dates (April 2, July 1, February 24)?
- Does the H2 average baseline produce more stable ETR values than monthly alternatives?
- What is the ETR spread (max - min across methods) at each point in the series?
