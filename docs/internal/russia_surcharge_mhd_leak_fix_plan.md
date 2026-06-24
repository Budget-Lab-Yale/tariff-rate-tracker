# Fix plan: Russia steel surcharge leak + too-strict annex_2 tests

> **Status:** diagnosed, fix NOT yet applied (plan only). Authored 2026-06-07.
> **Trigger:** 3 failing tests in `tests/test_rate_calculation.R` Test 12
> (annex-era country surcharges, rev_5 snapshot). Confirmed pre-existing and
> unrelated to the USMCA auto/MHD parts content-scaling fix (commit `99cca73`):
> a clean-tree baseline reproduced the identical 88 pass / 3 fail. These are
> Russia (country `4621`) cases; the parts fix is CA/MX-only.

## The three failures

| # | Test | Verdict |
|---|---|---|
| 1 | `Russia annex_2 products are NOT surcharged (annex II out of scope)` | **Test too strict** |
| 2 | `Russia steel (ch 72/73) does NOT get the aluminum-only surcharge` | **Real code bug** |
| 3 | `Annex II × rate_232>0 is semi-products-only (Note 39a invariant)` | **Test too strict** |

## Failure 2 — real code bug: `mhd_products` is not blanket-chapter-stripped

### Root cause

The leak is exactly the steel **springs** `7320.10.30 / .60 / .90` and `7320.20.10`
(4 HTS-8, 6 HTS-10 rows) for Russia, carrying `rate_232 = 2.0` while 1054 other
Russia annex_1a steel lines correctly carry `0.50`.

Chain of events:

1. `7320.x` springs are automotive suspension parts → listed in
   **both** `resources/s232_auto_parts.txt` and `resources/s232_mhd_parts.txt`.
2. `06_calculate_rates.R:1537` strips blanket steel/aluminum chapters (72/73/76)
   from `auto_products`:
   ```r
   auto_products <- auto_products[!substr(auto_products, 1, 2) %in% blanket_chapters]
   ```
   **There is no equivalent strip for `mhd_products`** (line ~1523 only removes
   semis). So via the MHD-parts list these ch73 springs survive in
   `heading_program_products` (line ~2140).
3. Step 4 sets Russia `steel_rate = 2.0` from the
   `section_232_country_exemptions` entry (`config/policy_params.yaml:228-231`,
   `applies_to: ['steel','aluminum']`), so the springs' `rate_232` is 2.0
   going into the annex stage.
4. The annex override (line ~2144) is
   `hts10 %in% heading_program_products ~ rate_232` — i.e. it **keeps the prior
   rate** for heading-program products instead of applying the annex_1a 0.50.
   Because the springs are (wrongly) still in `mhd_products`, they keep 2.0.

The comment at `06_calculate_rates.R:1531-1534` already names this exact case
("a Ch73 steel spring that matches auto_parts prefixes is still a steel
product … gets blanket 232 rate") — but the implementation only strips
`auto_products`, not `mhd_products`. Clear oversight.

Note the contrast that proves the scoping is otherwise correct: `7308.20`
(towers/masts) also shows `2.0` for Russia, but that is **correct** — it is a
listed *aluminum derivative*, so the aluminum-scoped surcharge legitimately
applies, and the test rightly excludes known aluminum-derivative prefixes. Only
the `7320` springs are the bug.

### Fix

Mirror the `auto_products` blanket-chapter strip onto `mhd_products`, at the same
site (right after `06_calculate_rates.R:1537`), before the
`parts_products`/`usmca_vehicle_products` derivation:

```r
n_mhd_pre <- length(mhd_products)
mhd_products <- mhd_products[!substr(mhd_products, 1, 2) %in% blanket_chapters]
if (length(mhd_products) < n_mhd_pre) {
  message('  Excluded ', n_mhd_pre - length(mhd_products),
          ' blanket chapter products from mhd_products')
}
```

Effect: steel/aluminum-chapter MHD parts leave the MHD heading set and receive
standard steel/aluminum annex treatment. The 6 Russia spring lines then take the
annex_1a 0.50 instead of retaining 2.0, and Failure 2 passes. `copper_products`
(ch74) and `wood_products` (ch44/94) do **not** intersect blanket chapters
72/73/76, so no strip is needed for them — only `mhd_products` is affected.

### Companion consideration (separate, optional — changes pre-annex behavior)

The `section_232_country_exemptions` Russia entry uses
`applies_to: ['steel','aluminum']`, but Proclamation 10522 (2023) was an
**aluminum** action. Applying a 200% rate to Russian *steel* at step 4 is
arguably wrong on its own merits; in the annex era the annex override masks it
for everything except the shielded springs, but **pre-annex** revisions would
carry Russian steel at 2.0. Narrowing the entry to `applies_to: ['aluminum']`
would be the more principled root fix. **Out of scope for the failing test** (the
`mhd_products` strip alone makes rev_5 correct), but worth a deliberate decision
because it touches pre-2026-04-06 snapshots. Recommend: evaluate separately with
a pre-annex Russia-steel snapshot check before changing.

## Failures 1 & 3 — too-strict tests: annex_2 preserves all heading programs

### Root cause

The 133 "leaking" rows are all `8703` / `8704` / `8407` (Russia passenger cars,
light trucks, engines) carrying the **auto 232 rate (~0.25)**. This is the
documented, intended behavior: `06_calculate_rates.R:2122-2151` deliberately
preserves *all* heading-program rates on `annex_2`, because the April-2026 annex
governs only steel/aluminum/copper — the auto (9903.94), MHD (9903.74), wood,
and semiconductor authorities are separate and unaffected by Annex II's
"removed from scope" language.

Both tests whitelist **only semis** as the allowed non-zero `rate_232` on
`annex_2`. They predate / ignore the broader heading-program preservation, so
they flag autos/MHD as leaks. The code is correct; the invariant is incomplete.

### Fix

Widen the whitelist in both tests from "semi only" to "all heading-program
products" (autos + MHD + copper + wood + semi). Concretely, build the exempt set
the same way the code does and exclude it before the `rate_232 == 0` /
`nrow(leak) == 0` assertions:

- **Test "Russia annex_2 products are NOT surcharged"** (`~line 856`): replace the
  `non_semi_a2 <- ru_a2 %>% filter(!(hts10 %in% semi))` step with a filter that
  drops all heading-program products, not just `semi`.
- **Test "Annex II × rate_232>0 is semi-products-only"** (`~line 908`): rename the
  invariant to "heading-program-only" and exclude the full heading-program set
  in the `leak` computation.

The heading-program HTS-10 set can be reconstructed in the test from the resource
files (`s232_auto_parts.txt`, `s232_mhd_parts.txt`, the auto/MHD vehicle heading
prefixes in `policy_params.yaml:section_232_headings`, `s232_copper_products.csv`,
the wood prefixes, `s232_semi_products.csv`) — or, more robustly, the snapshot
could carry a boolean `heading_program` column for tests to key on (larger
change; not required).

## Verification steps (when applying)

1. Apply the `mhd_products` strip (Failure 2) and the two test whitelist
   widenings (Failures 1 & 3).
2. **Rebuild the rev_5 snapshot** — the tests read the cached
   `data/timeseries/snapshot_2026_rev_5.rds` (a build artifact, not git-tracked,
   currently dated 2026-06-05). There is **no `--revision` single-snapshot flag**
   in `src/00_build_timeseries.R`; the entry points are `--full` (full backfill,
   writes every `snapshot_*.rds`), `--build-only` (skip downstream daily/ETR/
   quality), and the incremental `start_from` path (requires cached
   `ch99_<rev>.rds` / `products_<rev>.rds` state). Simplest reliable rebuild:
   ```bash
   # bare R + CRAN bundle lib path (R is not on PATH):
   export R_LIBS=/apps/software/2024a/software/R-bundle-CRAN/2024.11-foss-2024a:$HOME/r_libs_4.4
   RS=/apps/software/2024a/software/R/4.4.2-gfbf-2024a-bare/bin/Rscript
   $RS src/00_build_timeseries.R --full --build-only   # rebuilds all snapshots, skips downstream
   ```
   (32 GB RAM recommended for `--full`. If memory-constrained, use the
   `start_from` incremental path against the revision before rev_5.)
3. Re-run `Rscript tests/test_rate_calculation.R` → expect **91 pass / 0 fail**.
4. Sanity-check the snapshot: Russia `7320.x` annex_1a now `0.50` (not 2.0);
   Russia `7308.20` still `2.0` (aluminum derivative, correct); non-Russia steel
   unchanged; MHD steel parts for other countries now take steel annex rates
   rather than the 0.25 MHD heading rate (intended — verify no other Test-12
   assertion regresses).
5. Run the broader suites in CI order (`tests/run_tests_*.R`,
   `tests/test_rate_calculation.R`) to confirm the `mhd_products` behavioral
   change doesn't regress other expectations.

## Notes

- The `mhd_products` strip is a **global** behavioral change (all steel/alum MHD
  parts, every country/revision), not Russia-specific — that is the correct
  generalization of the existing `auto_products` strip, but it is why a full
  test rerun + snapshot rebuild is required before trusting it.
- Test environment: R is not on `PATH`; use
  `/apps/software/2024a/software/R/4.4.2-gfbf-2024a-bare/bin/Rscript` with
  `R_LIBS=/apps/software/2024a/software/R-bundle-CRAN/2024.11-foss-2024a:$HOME/r_libs_4.4`.
