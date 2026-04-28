# Dense Rate Export — Plan

**Author:** Requested by tariff-etr-eval project (see `C:/Users/ji252/Documents/GitHub/tariff-etr-eval`).
**Date:** 2026-04-17 (revised)

## Motivation

The downstream `tariff-etr-eval` project constructs a statutory effective tariff rate (ETR) following the definition

$$\tau^{s}_{t} \;=\; \frac{\sum_{c,p} i_{cp,2024}\,\tau^{s}_{cpt}}{\sum_{c,p} i_{cp,2024}}$$

where the sum runs over *every* (country $c$, product $p$) pair with positive 2024 imports. That requires $\tau^{s}_{cpt}$ to be defined for the **full HS10 × trading-country universe**, not just pairs with a Chapter-99 footnote.

The current tracker snapshots (`data/timeseries/snapshot_*.rds` → exported to eval as `snapshot_*.csv`) are **sparse**: `src/06_calculate_rates.R:62` filters `products` to `n_ch99_refs > 0` before the country cross-join, so products that carry only a base MFN rate never enter the footnote-based rate path. Pre-Liberation-Day (`snapshot_basic.rds`) this means ~274k rows — of which only ~20k intersect with the 2024 import-weights universe (~333k pairs). The other ~94% of pairs are silently zero-filled downstream, erasing their MFN contribution.

After Liberation Day the universal IEEPA reciprocal (9903.01.25) sticks a Chapter-99 reference onto nearly every product, so the snapshots balloon to ~4M rows and the blind spot closes — but the pre-April period is wrong, and the current daily ETR series has the same hole (numerator inner-joins on imports but timeseries is sparse).

## Deliverable

A **dense** per-revision snapshot covering every `(hts10, country)` pair where the product is in the parsed HS10 universe and the country is in the Census code list. Replaces the current `snapshot_*.rds` files in place — downstream CSV export is unchanged.

**Rows:** full outer join of
- the HS10 universe parsed in `src/04_parse_products.R` (which already carries a `base_rate` for every product — see `04_parse_products.R:83`), and
- the Census country universe passed into `calculate_rates_for_revision()` (see `00_build_timeseries.R` where it builds `countries <- census_codes$Code`).

For each pair:
- If the product had Chapter-99 references: the existing `calculate_rates_fast()` path fills authority columns as today.
- If the product had no Chapter-99 references (MFN-only): `total_rate = base_rate`, all `rate_*` authority columns = 0, `deriv_type = NA`, `usmca_eligible` / `s232_usmca_eligible` passed through from the parsed product.

**Columns:** the existing schema (`src/rate_schema.R`). No new columns. Downstream in `tariff-etr-eval` already expects the current set.

**Expected row count per revision:**
- basic: ~10k HS10 × ~240 Census codes ≈ 2.4M (vs 274k currently)
- post-Liberation Day: similar ~4M (already near full universe because of IEEPA universal)

File size grows ~10× for early revisions. RDS storage ~40–80 MB per file, CSV ~200 MB. Acceptable.

## Implementation

The tracker already contains the machinery needed for both pieces of this task. This plan reuses existing helpers rather than introducing parallel code paths.

### Part 1 — Densify snapshots by reusing the post-IEEPA grid-expansion block

`06_calculate_rates.R:909-943` already implements exactly the grid-densification step this project needs. It is currently gated on `ieepa_was_invalidated`. The fix is to:

1. **Extract** the block at `06_calculate_rates.R:909-943` into a helper in the same file, e.g.

    ```r
    #' Ensure rates has a row for every (hts10, country) pair in the product/country
    #' universe. MFN-only pairs get zero for all authority columns; base_rate is
    #' joined from the parsed products table. Downstream blanket authorities (232,
    #' 301, s122) then fill in on the complete grid.
    ensure_dense_grid <- function(rates, products, countries) {
      existing_pairs <- rates %>% select(hts10, country)

      all_products_base <- products %>%
        select(hts10, base_rate) %>%
        mutate(base_rate = coalesce(base_rate, 0))

      new_pairs <- all_products_base %>%
        tidyr::expand_grid(country = countries) %>%
        anti_join(existing_pairs, by = c('hts10', 'country')) %>%
        mutate(
          rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
          rate_ieepa_fent = 0, rate_s122 = 0,
          rate_section_201 = 0, rate_other = 0
        )

      if (nrow(new_pairs) > 0) {
        message('  Grid expansion: adding ', nrow(new_pairs),
                ' MFN-only product-country pairs')
        rates <- bind_rows(rates, new_pairs)
      }
      rates
    }
    ```

2. **Replace** the body of the existing `ieepa_was_invalidated` block with a call to `ensure_dense_grid(rates, products, countries)`, so behavior in the IEEPA-invalidated branch is unchanged.

3. **Call the helper unconditionally** — insert one line between step 6d (floor recomputation) and step 7 (USMCA exemptions). Placing it *after* the footnote/blanket authority passes but *before* USMCA means:
   - 232, 301, s122, fentanyl, IEEPA recip have already been written onto the footnote-matched rows (correct).
   - MFN-only pairs enter with all authority columns = 0, base_rate populated (correct).
   - USMCA exemption logic then runs over the dense grid and applies correctly to CA/MX rows that previously never existed.

Why not call it earlier? Placing the expansion before the blanket passes would work (those passes `left_join` country-level rates onto the existing grid) but would cost memory on steps that currently operate on a smaller frame. After the blanket passes is cheaper. Either is correct — verify with one run.

**Verification before shipping:** re-run the TPC validation step (`validate_revision_against_tpc`) on rev_6, rev_10, rev_17, rev_18, rev_32 and confirm match rates are unchanged vs. the pre-dense baseline (±0.1 pp). The dense rows are MFN-only — they do not change rates on any product that was in the old snapshot.

**Why not also drop the `n_ch99_refs > 0` filter in `calculate_rates_fast()` itself?** The filter at `06_calculate_rates.R:62` (`products_expanded`) is effectively dead code — `products_expanded` is assigned but never used downstream inside that function. The filter that actually matters is at line 76 (`product_refs`), which exists for good reason: products without ch99 refs have nothing to unnest, so passing them through the `left_join` → `pivot_wider` path would either drop them (inner_join semantics) or produce NA-filled junk rows. Adding the grid post-hoc is strictly cleaner than trying to weave MFN-only pairs through a pipeline designed around ch99 refs.

### Part 2 — Four USMCA scenarios, reusing `build_alternative_timeseries()`

`09_daily_series.R:799 build_alternative_timeseries()` already:
- accepts a `pp_override` list (no yaml edits needed),
- loops all revisions and calls `calculate_rates_for_revision()` for each,
- writes per-revision snapshots to a tempdir,
- builds daily aggregates and scenario outputs.

Calls at `09_daily_series.R:986-1034` already build `usmca_annual`, `usmca_monthly`, `usmca_2024`, `usmca_dec2025` scenarios end-to-end. The four scenarios eval needs map onto that harness directly.

**Changes required:**

1. **Add `usmca_none` support.** Two options, in rough order of preference:
   - (a) Extend `load_usmca_product_shares()` in `src/data_loaders.R` to recognize `mode == 'none'` and return a table that yields 0% utilization for every (hts10, country). The stacking path is then exercised unchanged.
   - (b) Add a `usmca_none` scenario to `config/scenarios.yaml` consumed via `apply_scenario()` (see `src/apply_scenarios.R:62`). Only worth doing if (a) requires touching internals that are hard to justify.

   Prefer (a) — it keeps the scenario semantics inside the same config surface (`usmca_shares.mode`) that the other three scenarios use.

2. **Persist snapshots per scenario.** `build_alternative_timeseries()` currently writes snapshots to `tempfile(...)` and deletes on exit. For this export we want them kept under `data/timeseries/<scenario>/`.

   Add a `snapshot_out_dir` argument (default `NULL`, preserves current tempdir behavior). When non-null, write per-revision snapshots there instead, and skip the `on.exit(unlink(...))`. Roughly:

    ```r
    build_alternative_timeseries <- function(pp_override, variant_name,
                                              ...,
                                              snapshot_out_dir = NULL) {
      if (is.null(snapshot_out_dir)) {
        tmp_dir <- tempfile(paste0('alt_snapshots_', variant_name, '_'))
        dir.create(tmp_dir)
        on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
      } else {
        tmp_dir <- snapshot_out_dir
        dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
      }
      # ... existing loop, unchanged ...
    }
    ```

   The daily-aggregate path downstream in the same function reads from `tmp_dir` and is unaffected.

3. **Invoke the scenarios.** A small wrapper — or an inline block in `09_daily_series.R` next to the existing usmca_* blocks — that calls `build_alternative_timeseries()` for each of:

   | Scenario label   | `usmca_shares.mode` | `year` | `snapshot_out_dir`                  |
   | ---------------- | ------------------- | ------ | ----------------------------------- |
   | `usmca_none`     | `none`              | —      | `data/timeseries/usmca_none/`       |
   | `usmca_2024`     | `annual`            | 2024   | `data/timeseries/usmca_2024/`       |
   | `usmca_monthly`  | `monthly`           | 2025   | `data/timeseries/usmca_monthly/`    |
   | `usmca_h2avg`    | `h2_average`        | 2025   | `data/timeseries/usmca_h2avg/`      |

   Top-level `data/timeseries/snapshot_*.rds` continues to be written by the main `00_build_timeseries.R` run. These *are* the h2avg scenario (that's the production default in `config/policy_params.yaml`), so `data/timeseries/usmca_h2avg/` is redundant content-wise but useful for layout symmetry on the eval side — every scenario lives at a predictable `data/timeseries/<scenario>/` path, with no "and h2avg is the one at top level" special case leaking into downstream scripts.

4. **h2avg: verify-once, then copy.** Don't re-run `build_alternative_timeseries()` with `mode='h2_average'` on every build — that's 15 min of duplicate compute and ~1 GB of duplicate storage for a result that must equal the top-level output. Instead:
   - **First time only**, run `build_alternative_timeseries(mode='h2_average', snapshot_out_dir='data/timeseries/usmca_h2avg/', ...)` and diff the resulting snapshots against the top-level ones. Expect byte-identical (or within floating-point tolerance). Any drift is a real bug in one of the two paths and needs to be resolved before shipping.
   - **Thereafter**, populate `data/timeseries/usmca_h2avg/` with a post-build copy from top-level `data/timeseries/snapshot_*.rds`. Roughly one line at the tail of `00_build_timeseries.R` or in the scenario harness:

    ```r
    snap_files <- list.files(output_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)
    h2avg_dir <- file.path(output_dir, 'usmca_h2avg')
    dir.create(h2avg_dir, recursive = TRUE, showWarnings = FALSE)
    file.copy(snap_files, h2avg_dir, overwrite = TRUE)
    ```

Runtime for the three genuinely alternative scenarios (`usmca_none`, `usmca_2024`, `usmca_monthly`): ~15 min each × 3 = ~45 min. Gated behind a `--with-scenarios` (or similar) flag so the default nightly build is unaffected. The h2avg copy step is cheap (~a few seconds) and can always run.

### Output layout

```
data/timeseries/
├── snapshot_basic.rds          # production (h2avg-equivalent, unchanged path)
├── snapshot_rev_1.rds
├── ...
├── usmca_none/
│   ├── snapshot_basic.rds
│   └── snapshot_rev_*.rds
├── usmca_2024/
├── usmca_monthly/
└── usmca_h2avg/                # post-build copy of top-level snapshots (see h2avg note above)
```

The eval project's `code/R/00_pull_raw_data.R` reads from the four subdirectories.

## Validation

Before declaring done, check:

1. Row counts per revision are in the expected range (2.4M–4M). Log a warning if any revision has <1M rows.
2. For each revision, `n_distinct(hts10)` equals the HS10 count in the *post-parse* products table (i.e., after `04_parse_products.R` filtering — Ch98/invalid entries already excluded). Within tolerance for products whose `base_rate` parse failed.
3. For each revision, `n_distinct(country)` equals `length(census_codes$Code)`.
4. Spot-check: pick 5 products with `n_ch99_refs == 0` (MFN-only). Confirm `total_rate == base_rate` across all countries except USMCA-eligible CA/MX pairs (where USMCA may zero it).
5. Spot-check: pick 5 products with `n_ch99_refs > 0`. Confirm their rates match the current (sparse) snapshot within floating-point tolerance on matched rows.
6. **TPC match rate regression check:** rerun validation for rev_6, rev_10, rev_17, rev_18, rev_32. Match rates should not drop. If they do, the grid expansion is interacting with a stacking rule that wasn't written to expect MFN-only rows.
7. Daily ETR output (`data/daily/daily_overall.csv`) should be **higher** for pre-Liberation-Day months by ~1–2 pp (the reclaimed MFN contribution) but unchanged post-Apr 2025. Treat as a correction, not a regression.

## Impact on other tracker outputs

- **Daily ETR (`src/09_daily_series.R`)** — will shift for pre-April-2025 dates. Numerator grows as MFN-only pairs gain nonzero rates × matched imports; denominator unchanged. Expect ~1–2 pp upward revision for Jan–Mar 2025, ~0 shift afterward.
- **`export_for_etrs.R`** — unchanged in structure; `rates_snapshot.csv` row count grows proportionally. Downstream ETRs replication should be validated (likely no headline change since it already uses an MFN-base table via `mfn_rates_path`).
- **`statutory_rates.csv.gz`** from `generate_etrs_config.R:171` — grows proportionally; consumers should be notified.

## Open questions for tracker maintainer

1. Any pre-Liberation-Day revisions where `04_parse_products.R` has known HS10 gaps? The dense export will newly expose any such gaps as "missing MFN coverage" in eval.
2. Is extending `load_usmca_product_shares()` with `mode == 'none'` OK, or should it be a scenario yaml (via `apply_scenario()`) instead?
3. Is `data/timeseries/<scenario>/` the right layout, or should scenario snapshots live under `data/timeseries/scenarios/<scenario>/` to keep the top-level cleaner?

## Handoff

Once the four scenario snapshot sets exist, the eval project will:

1. Update `code/R/00_pull_raw_data.R` to pull from all four scenario subdirectories and write `data/raw/snapshot_rates/{scenario}/snapshot_*.csv`.
2. Rewrite the Stata Tier 1 / Tier 2 construction to use the dense, per-scenario rate tables.
3. Retire the reconstructed `counterfactual_usmca*.csv` files (their job is now done at the tracker).

No further change should be needed in the tracker after this handoff.
